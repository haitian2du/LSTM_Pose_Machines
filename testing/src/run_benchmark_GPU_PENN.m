function prediction_file = run_benchmark_GPU_PENN(param, benchmark_modelID)

model = param.model(benchmark_modelID);
testAdd = model.testAdd; 

sigma = 21;
scale_search = 0.8:0.1:1.4; % 7 scale(consistent with training), if you change this, you also need to modify the prototxt input dim.
boxsize = model.boxsize;
stride = model.stride;
np = model.np;

orderToPENN = [1 3 6 4 7 5 8 9 12 10 13 11 14]; %ignore the second one which is the neck
torso_norm = 0; %1:Torso / 0:bbox; default as 0 -> 0.2*max(h,w)

obj = zeros(1,length(orderToPENN));
detected = zeros(1,length(orderToPENN));

%deploy the testing network
deployFile1 = model.deployFile_1;
deployFile2 = model.deployFile_2;
caffemodel = model.trainedModel;

net1 = caffe.Net(deployFile1,'test');
net1.copy_from(caffemodel);

net2 = caffe.Net(deployFile2,'test');
net2.copy_from(caffemodel);

fprintf('Running inference using model %s, %d scales for each sample.\n', model.description, length(scale_search));

prediction.sequences = cell(1068,1);

for i= 1:12
    data = strcat('testSet',num2str(i),'.mat' );
    fprintf('load test mat file %d....\n',i);
    testDataAdd = strcat(testAdd,data);
    testData  = load(testDataAdd);
    test = testData.test;
    clear testData;
    numSeq = test.numSeqInSet;

    for j = 1:numSeq
        dim = [size(test.sequence{j}.frame{1}.image,1) size(test.sequence{j}.frame{1}.image,2)];
        testIter = (i-1)*numSeq + j;
        if (test.sequence{j}.train ~= -1)
            fprintf('Sequence %d in set %d does not belong to testing ...\n',j,i);
        end
        fprintf('Processing Seq %d / 1068 .....\n',testIter );

        %save summary information
        prediction.sequences{testIter}.nframes = test.sequence{j}.nframes;
        prediction.sequences{testIter}.frameAdd = test.sequence{j}.frameAdd;
        prediction.sequences{testIter}.labelAdd = test.sequence{j}.labelAdd;
        prediction.sequences{testIter}.predLabel = zeros([2 length(orderToPENN) test.sequence{j}.nframes]);
        
        %create center_map
        center_map_single = produceCenterLabelMap([boxsize boxsize], boxsize/2, boxsize/2, sigma);
        center_map = repmat(center_map_single,[1 1 1 length(scale_search)]);

        seqLength = test.sequence{j}.nframes;
        %used to save the result and intermediate information.
        heatmap = zeros([boxsize/stride boxsize/stride np+1 seqLength length(scale_search)],'single');
        h_stage = cell(1,seqLength);
        cell_stage = cell(1,seqLength);
        
        offset = zeros([length(scale_search) 2 seqLength]);
        Resize = zeros([length(scale_search) 2 seqLength]);
        label = zeros([3 13 seqLength]);
        bbox = zeros([seqLength 4]);
    
        time0 = tic;
        for n=1:seqLength
            if(n==1)
                [image, label(:,:,n), bbox(n,:), offset(:,:,n), Resize(:,:,n)] = transform_test(test.sequence{j},n,scale_search,boxsize);
                %%for the first initial stage without memory, requires extra process
                data_1st = gather(image);
                net1.blobs('data1').set_data(single(data_1st)); %process several multipler together
                net1.blobs('data2').set_data(single(data_1st));
                net1.blobs('center_map').set_data(single(center_map));
                net1.forward_prefilled();

                heatmap(:,:,:,1,:) = net1.blobs('Mconv5_stage2').get_data();
                h_stage{1} = net1.blobs('h_stage2').get_data();
                cell_stage{1} = net1.blobs('Cell_stage2').get_data();
            else
                %following frames
                [image, label(:,:,n), bbox(n,:), offset(:,:,n), Resize(:,:,n)] = transform_test(test.sequence{j},n,scale_search,boxsize);
                data_nth = gather(image);
                net2.blobs('data').set_data(single(data_nth));
                heatmap_reshape = reshape(heatmap(:,:,:,n-1,:),boxsize/stride,boxsize/stride,np+1,length(scale_search));
                net2.blobs('heatmap').set_data(single(heatmap_reshape));
                net2.blobs('h_t_1').set_data(single(h_stage{n-1}));
                net2.blobs('cell_t_1').set_data(single(cell_stage{n-1}));
                net2.blobs('center_map').set_data(single(center_map));
                net2.forward_prefilled();

                heatmap(:,:,:,n,:) = net2.blobs('Mres5_stage3').get_data();
                h_stage{n} = net2.blobs('h_stage3').get_data();
                cell_stage{n} = net2.blobs('Cell_stage3').get_data();
            end    
        end
            fprintf('Total Process time for seqLength=%d is %.4fs ...\n',seqLength,toc(time0));
        clear image;
        prediction.sequences{testIter}.label = label;
        prediction.sequences{testIter}.bbox = bbox;
               
        for frame = 1:seqLength %each frame
            heat_ = reshape(heatmap(:,:,:,frame,:),boxsize/stride,boxsize/stride,np+1,length(scale_search));
            heat_gpu = heat_;%gpuArray(heat_);
            heatmap_full = single(zeros([dim(1) dim(2) np+1 length(scale_search)]));
            for scale = 1:length(scale_search)
                heatmap_large(:,:,:,scale) = imresize(heat_gpu(:,:,:,scale),stride);
                heatmap_full(:,:,:,scale) = imgRepos(heatmap_large(:,:,:,scale),offset(scale,:,frame),dim,Resize(scale,:,frame));
            end
            clear heatmap_large;

            final_score = zeros([size(heatmap_full,1) size(heatmap_full,2) np]);
            for scale_final = 1:size(heatmap_full,4) %combine all scales
               final_score = final_score + heatmap_full(:,:,1:np,scale_final);
            end
            score = final_score(:,:,orderToPENN);  

            pred_x= zeros(1,length(orderToPENN));
            pred_y= zeros(1,length(orderToPENN));
            for joints = 1:length(orderToPENN) 
                [pred_y(joints),pred_x(joints)] = findMaximum(score(:,:,joints));
                prediction.sequences{testIter}.predLabel(1,joints,frame) = pred_x(joints);
                prediction.sequences{testIter}.predLabel(2,joints,frame) = pred_y(joints);
            end

            %PCK0.2 dectection
            if(torso_norm == 1)
                bodysize = norm([label(1,3,frame),label(2,3,frame)] - [label(1,8,frame),label(2,8,frame)]);
                if(bodysize<1)
                    bodysize = norm([pred_x(3),pred_y(3)] - [pred_x(8),pred_y(8)]);
                end
            else
                bodysize = max(bbox(frame,3)-bbox(frame,1),bbox(frame,4)-bbox(frame,2));
            end

            for joints = 1:length(orderToPENN)
                hit=2;
                if(label(3,joints,frame)==1)
                    error_dist = norm([pred_x(joints),pred_y(joints)] - [label(1,joints,frame),label(2,joints,frame)]);

                    hit = error_dist <= bodysize*0.2;

                    obj(joints) = obj(joints) + 1;
                    if(hit)
                        detected(joints) = detected(joints) + 1;
                    end
                end
                fprintf(' %d', hit);
            end
            fprintf(' |');
            for joints = 1:length(orderToPENN)
                if(obj(joints)==0)
                    fprintf(' 0');
                else
                    fprintf(' %.3f', detected(joints)/obj(joints));
                end
            end
            if(sum(obj)==0)
                fprintf(' ||0\n');
            else
                fprintf(' ||%.4f\n', sum(detected)/sum(obj));
            end
        end
    end
end


prediction_file = sprintf('predicts/%s.mat', model.description_short);
save(prediction_file, 'prediction');

end

function [image, label ,bbox, offset, Resize] = transform_test(sequence, seqID, scale_search, boxsize)

    img = sequence.frame{seqID}.image;
    imageOri = gpuArray( (single(img)-128)/256 );
    image = gpuArray(zeros([boxsize boxsize 3 length(scale_search)],'single'));
    label(1,:)= sequence.frame{seqID}.label.x;
    label(2,:)= sequence.frame{seqID}.label.y;
    label(3,:)= double(sequence.frame{seqID}.label.visibility);
    bbox = sequence.frame{seqID}.bbox;
    offset = zeros([length(scale_search) 2]);
    Resize = zeros([length(scale_search) 2]);
        
    for i = 1:length(scale_search)
		%fprintf('scale %.2f ...\n',scale_search(i));
        [image_resize, bbox_resize] = imgScale(imageOri, bbox, scale_search(i),boxsize);
        Resize(i,1) = size(image_resize,1); %keep record for the size of resized image.
        Resize(i,2) = size(image_resize,2);

        [image(:,:,:,i) , offset(i,:) ] = imgCrop(image_resize,bbox_resize,boxsize);
        clear image_resize;
    end
    clear imageOri; %release GPU memory
    image = preprocess(image);
end

function [image_resize , bbox_resize] = imgScale(image,bbox,scale,boxsize)

    bbox_resize = bbox .* scale;

    %To make sure all the box are within the boxsize. Information of joints will not get lost.
    maxBox = max([bbox_resize(3)-bbox_resize(1),bbox_resize(4)-bbox_resize(2)]);

    %Resize directly will not involve any special transformation of box & labels
    if( maxBox > boxsize ) %If preprocess image already too large. Make sure the bounding box is contained in the box.
       smaller_scale = scale*(boxsize / maxBox) / 1.05  ;
       %fprintf('   The multiplier %.2f is set too big...restrict to smaller one: %.2f\n',scale,smaller_scale);
    else
       smaller_scale = scale ;
    end
 
    image_resize = imresize(image,smaller_scale);

    bbox_resize = bbox .* smaller_scale;
end

function [image_crop , offset] = imgCrop(image_resize, bbox_resize, boxsize)

    image_crop = gpuArray(zeros([boxsize,boxsize,3],'single'));
    offset = zeros([1 2]);
    
    center_x = round( (bbox_resize(1) + bbox_resize(3)) / 2 );
    center_y = round( (bbox_resize(2) + bbox_resize(4)) / 2 );

    left = min(center_x-1, boxsize/2-1);
    up   = min(center_y-1, boxsize/2-1);
    right = min(size(image_resize,2)-center_x, boxsize/2);
    down = min(size(image_resize,1)-center_y, boxsize/2);
    try
        image_crop(boxsize/2-up:boxsize/2+down, boxsize/2-left:boxsize/2+right,:) = image_resize(center_y-up:center_y+down, center_x-left:center_x+right,:);
    catch
        error('      something wrong happens in cropping....\n');
    end
    offset(1) = (boxsize/2) - (center_x);
    offset(2) = (boxsize/2) - (center_y);
end

function label = produceCenterLabelMap(im_size, x, y, sigma) %this function is only for center map in testing
    [X,Y] = meshgrid(1:im_size(1), 1:im_size(2));
    X = X - x;
    Y = Y - y;
    D2 = X.^2 + Y.^2;
    Exponent = D2 ./ 2.0 ./ sigma ./ sigma;
    label = exp(-Exponent);
end

function img_out = preprocess(img)
    img_out = permute(img, [2 1 3 4]);
    img_out = img_out(:,:,[3 2 1],:);
end

function heatmap_rePos = imgRepos(heatmap_large,offset,dim,Resize)
    heatmap_rePos = zeros([Resize(1) Resize(2) size(heatmap_large,3)-1],'single');
    heatmap_rePos(:,:,size(heatmap_large,3)) = ones([Resize(1) Resize(2)],'single');
    heatmap_rePos = gpuArray(heatmap_rePos);

    heatmap_large = permute(heatmap_large,[2 1 3]);

    heatmap_rePos( max(1,-offset(2)+1):min(size(heatmap_large,1)-offset(2),Resize(1)), max(1,-offset(1)+1):min(size(heatmap_large,2)-offset(1),Resize(2)),:) = heatmap_large( max(1,offset(2)+1):min(size(heatmap_large,1),Resize(1)+offset(2)),max(1,offset(1)+1):min(size(heatmap_large,2),Resize(2)+offset(1)),:);

    heatmap_rePos = imresize(gather(heatmap_rePos),[dim(1) dim(2)]);
end

function [x,y] = findMaximum(map)
    [~,i] = max(map(:));
    [x,y] = ind2sub(size(map), i);
end
