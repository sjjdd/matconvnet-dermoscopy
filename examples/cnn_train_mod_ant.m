function [net, info] = cnn_train_mod(net, net_seg, imdb, getBatch, varargin)
%CNN_TRAIN  An example implementation of SGD for training CNNs
%    CNN_TRAIN() is an example learner implementing stochastic
%    gradient descent with momentum to train a CNN. It can be used
%    with different datasets and tasks by providing a suitable
%    getBatch function.
%
%    The function automatically restarts after each training epoch by
%    checkpointing.
%
%    The function supports training on CPU or on one or more GPUs
%    (specify the list of GPU IDs in the `gpus` option). Multi-GPU
%    support is relatively primitive but sufficient to obtain a
%    noticable speedup.

% Copyright (C) 2014-15 Andrea Vedaldi.
% All rights reserved.
%
% This file is part of the VLFeat library and is made available under
% the terms of the BSD license (see the COPYING file).

opts.expDir = fullfile('data','exp') ;
opts.continue = true ;
opts.batchSize = 256 ;
opts.numSubBatches = 1 ;
opts.train = [] ;
opts.val = [] ;
opts.gpus = [] ;
opts.prefetch = false ;
opts.numEpochs = 300 ;
opts.learningRate = 0.001 ;
opts.weightDecay = 0.0005 ;
opts.momentum = 0.9 ;
opts.memoryMapFile = fullfile(tempdir, 'matconvnet.bin') ;
opts.profile = false ;

opts.numArch = 1 ;
opts.GrayScale = 0 ;
opts.useGpu =  false;
opts.numSet =  1;
opts.conserveMemory = true ;
opts.backPropDepth = +inf ;
opts.sync = false ;
opts.cudnn = true ;
opts.errorFunction = 'ap' ;
opts.errorLabels = {} ;
opts.plotDiagnostics = false ;
opts.plotStatistics = true;
opts.perf_data=struct('labels',[],'predictions',[],'perf',[]);
opts.validLabelsError = 1;
opts = vl_argparse(opts, varargin) ;


if ~exist(opts.expDir, 'dir'), mkdir(opts.expDir) ; end
if isempty(opts.train), opts.train = find(imdb.images.set==1) ; end
if isempty(opts.val), opts.val = find(imdb.images.set==2) ; end
if isnan(opts.train), opts.train = [] ; end
if isnan(opts.val), opts.val = [] ; end

% -------------------------------------------------------------------------
%                                                    Network initialization
% -------------------------------------------------------------------------

net = vl_simplenn_tidy(net); % fill in some eventually missing values
net.layers{end-1}.precious = 1; % do not remove predictions, used for error
vl_simplenn_display(net, 'batchSize', opts.batchSize) ;

evaluateMode = isempty(opts.train) ;

if ~evaluateMode
  for i=1:numel(net.layers)
    if isfield(net.layers{i}, 'weights'); 
      J = numel(net.layers{i}.weights) ;
      if ~isfield(net.layers{i}, 'learningRate') 
        net.layers{i}.learningRate = ones(1, J, 'single') ;
      end
      if ~isfield(net.layers{i}, 'weightDecay')
        net.layers{i}.weightDecay = ones(1, J, 'single') ;
      end
      if i<(numel(net.layers)-opts.backPropDepth)
          net.layers{i}.learningRate = zeros(1, J, 'single') ;
      end
      for j=1:J
          if net.layers{i}.learningRate(j)>0
            net.layers{i}.momentum{j} = zeros(size(net.layers{i}.weights{j}), 'single') ;
          end
      end
    end
  end
end

% setup GPUs
numGpus = numel(opts.gpus) ;
if numGpus > 1
  if isempty(gcp('nocreate')),
    parpool('local',numGpus) ;
    spmd, gpuDevice(opts.gpus(labindex)), end
  end
elseif numGpus == 1
  gpuDevice(opts.gpus)
end
if exist(opts.memoryMapFile), delete(opts.memoryMapFile) ; end

% setup error calculation function
hasError = true ;
if isstr(opts.errorFunction)
  switch opts.errorFunction
    case 'none'
      opts.errorFunction = @error_none ;
      hasError = false ;
    case 'multiclass'
      opts.errorFunction = @error_multiclass ;
      if isempty(opts.errorLabels), opts.errorLabels = {'top1err', 'top5err'} ; end
    case 'binary'
      opts.errorFunction = @error_binary ;
      if isempty(opts.errorLabels), opts.errorLabels = {'binerr'} ; end
    case 'auc'
      opts.errorFunction = @error_auc ;
      if isempty(opts.errorLabels), opts.errorLabels = {'auc'} ; end  
     case 'ap'
      opts.errorFunction = @error_ap ;
      if isempty(opts.errorLabels), opts.errorLabels = {'ap'} ; end    
    otherwise
      error('Unknown error function ''%s''.', opts.errorFunction) ;
  end
end

% -------------------------------------------------------------------------
%                                                        Train and validate
% -------------------------------------------------------------------------

modelPath = @(ep) fullfile(opts.expDir, sprintf('net-epoch-%d.mat', ep));
modelFigPath = fullfile(opts.expDir, 'net-train.pdf') ;

start = opts.continue * findLastCheckpoint(opts.expDir) ;
if start >= 1
  fprintf('%s: resuming by loading epoch %d\n', mfilename, start) ;
  load(modelPath(start), 'net', 'info') ;
  net = vl_simplenn_tidy(net) ; % just in case MatConvNet was updated
% else
%   save(modelPath(0), 'net','-v7.3') ;
end

for epoch=start+1:opts.numEpochs

  % train one epoch and validate
  learningRate = opts.learningRate(min(epoch, numel(opts.learningRate))) ;
  train = opts.train(randperm(numel(opts.train))) ; % shuffle
  
  val = opts.val;

  if numGpus <= 1
    [net,stats.train,prof] = process_epoch(opts, getBatch, epoch, train, learningRate, imdb, net, net_seg) ;
    if(~isempty(val))
        [~,stats.val] = process_epoch(opts, getBatch, epoch, val, 0, imdb, net,net_seg) ;
    end
    if opts.profile
      profile('viewer') ;
      keyboard ;
    end
  else
    fprintf('%s: sending model to %d GPUs\n', mfilename, numGpus) ;
    spmd(numGpus)
      [net_, stats_train_,prof_] = process_epoch(opts, getBatch, epoch, train, learningRate, imdb, net,net_seg) ;
      [~, stats_val_] = process_epoch(opts, getBatch, epoch, val, 0, imdb, net_,net_seg) ;
    end
    net = net_{1} ;
    stats.train = sum([stats_train_{:}],2) ;
    stats.val = sum([stats_val_{:}],2) ;
    if opts.profile
      mpiprofile('viewer', [prof_{:,1}]) ;
      keyboard ;
    end
    clear net_ stats_train_ stats_val_ ;
  end

  % save
  if evaluateMode, sets = {'val'} ; else sets = {'train', 'val'} ; end
  for f = sets
    f = char(f) ;
    n = numel(eval(f)) ;
    info.(f).speed(epoch) = n / stats.(f)(1) * max(1, numGpus) ;
    info.(f).objective(epoch) = stats.(f)(2) / n ;
    info.(f).error(:,epoch) = stats.(f)(3) / n ;
  end
  if ~evaluateMode
    fprintf('%s: saving model for epoch %d\n', mfilename, epoch) ;
    tic ;
    save(modelPath(epoch), 'net', 'info','-v7.3') ;
    fprintf('%s: model saved in %.2g s\n', mfilename, toc) ;
  end

  if opts.plotStatistics
    switchfigure(1) ; clf ;
    subplot(1,1+hasError,1) ;
    if ~evaluateMode
      semilogy(1:epoch, info.train.objective, '.-', 'linewidth', 2) ;
      hold on ;
    end
    semilogy(1:epoch, info.val.objective, '.--') ;
    xlabel('training epoch') ; ylabel('energy') ;
    grid on ;
    h=legend(sets) ;
    set(h,'color','none');
    title('objective') ;
    if hasError
      subplot(1,2,2) ; leg = {} ;
      if ~evaluateMode
        plot(1:epoch, info.train.error', '.-', 'linewidth', 2) ;
        hold on ;
        leg = horzcat(leg, strcat('train ', opts.errorLabels)) ;
      end
      plot(1:epoch, info.val.error', '.--') ;
      leg = horzcat(leg, strcat('val ', opts.errorLabels)) ;
      set(legend(leg{:},'Location','south'),'color','none') ;
      grid on ;
      xlabel('training epoch') ; ylabel('perf') ;
      title('error') ;
    end
    drawnow ;
    print(1, modelFigPath, '-dpdf') ;
  end
end

% -------------------------------------------------------------------------
function err = error_multiclass(opts, labels, res)
% -------------------------------------------------------------------------
predictions = gather(res(end-1).x) ;
[~,predictions] = sort(predictions, 3, 'descend') ;

% be resilient to badly formatted labels
if numel(labels) == size(predictions, 4)
  labels = reshape(labels,1,1,1,[]) ;
end

% skip null labels
mass = single(labels(:,:,1,:) > 0) ;
if size(labels,3) == 2
  % if there is a second channel in labels, used it as weights
  mass = mass .* labels(:,:,2,:) ;
  labels(:,:,2,:) = [] ;
end

m = min(5, size(predictions,3)) ;

error = ~bsxfun(@eq, predictions, labels) ;
err(1,1) = sum(sum(sum(mass .* error(:,:,1,:)))) ;
err(2,1) = sum(sum(sum(mass .* min(error(:,:,1:m,:),[],3)))) ;

% -------------------------------------------------------------------------
function err = error_binary(opts, labels, res)
% -------------------------------------------------------------------------
predictions = gather(res(end-1).x) ;
predictions = squeeze(predictions(:,:,2,:));
labels_signed=labels;
labels_signed(labels==1)=-1;
labels_signed(labels==2)=1;
error = bsxfun(@times, predictions, labels_signed) < 0 ;
err = sum(error(:)) ;

% -------------------------------------------------------------------------
function err = error_auc(opts, labels, res)
% -------------------------------------------------------------------------
%Si solo hay una salida

if(size(res(end-1).x,3)==1)
    predictions=squeeze(gather(res(end-1).x));
    posClass=1;
    labels=labels';
%Si tenemos mas de una    
else
    predictions=squeeze(gather(res(end-1).x));
    predictions=predictions(1,:)';
    labels=labels(1,:)';
    posClass=1;
    %Antiguo softmax
    %predictions = vl_nnsoftmax(gather(res(end-1).x)) ;
    %predictions=squeeze(predictions(:,:,2,:));
    %posClass=2;
end

tlabels=[opts.perf_data.labels;labels];
tpredictions=[opts.perf_data.predictions;predictions];
[X,Y,T,auc] = perfcurve(labels,predictions,posClass);
err.labels = tlabels;
err.predictions = tpredictions;
err.perf = auc;

% -------------------------------------------------------------------------
function err = error_ap(opts, labels, res)
% -------------------------------------------------------------------------
%Si solo hay una salida
if(size(res(end-1).x,3)==1)
    predictions=squeeze(gather(res(end-1).x));
    labels=labels(opts.validLabelsError>0,:)';
    labels(labels<0)=0;

else
    predictions= vl_nnsoftmax(res(end-1).x,[]);
    predictions = squeeze(predictions(:,:,2,:));
    labels=labels';
    labels(labels==1)=0;
    labels(labels==2)=1;
end
    

tlabels=[opts.perf_data.labels;labels];
tpredictions=[opts.perf_data.predictions;predictions];
numPat=size(tlabels,2);
if(numPat>1)
    ap=zeros(1,numPat);
    for i=1:1:numPat
        ap(i) = computeAP(tpredictions(:,i),tlabels(:,i)); 
        if(isnan(ap(i)))
            disp('error ap nan');
            ap(i)=0;
        end
    end
else
    ap = computeAP(tpredictions,tlabels); 
end
err.labels = labels;
err.predictions = predictions;
err.perf = ap;


% -------------------------------------------------------------------------
function err = error_none(opts, labels, res)
% -------------------------------------------------------------------------
err = zeros(0,1) ;

% -------------------------------------------------------------------------
function  [net_cpu,stats,prof] = process_epoch(opts, getBatch, epoch, subset, learningRate, imdb, net_cpu,net_seg_cpu)
% -------------------------------------------------------------------------

% move the CNN to GPU (if needed)
numGpus = numel(opts.gpus) ;
if numGpus >= 1
  net = vl_simplenn_move(net_cpu, 'gpu') ;
  net_seg = vl_simplenn_move(net_seg_cpu, 'gpu') ;
  one = gpuArray(single(1)) ;
else
  net = net_cpu ;
  net_seg=net_seg_cpu;
  net_cpu = [] ;
  net_seg_cpu = [];
  one = single(1) ;
end

% assume validation mode if the learning rate is zero
training = learningRate > 0 ;
if training
  mode = 'train' ;
  evalMode = 'normal' ;
else
  mode = 'val' ;
  evalMode = 'test' ;
end

% turn on the profiler (if needed)
if opts.profile
  if numGpus <= 1
    prof = profile('info') ;
    profile clear ;
    profile on ;
  else
    prof = mpiprofile('info') ;
    mpiprofile reset ;
    mpiprofile on ;
  end
end

res = [] ;
res_seg = [];
mmap = [] ;
stats = [] ;
start = tic ;


for t=1:opts.batchSize:numel(subset)
  fprintf('%s: epoch %02d: %3d/%3d: ', mode, epoch, ...
          fix(t/opts.batchSize)+1, ceil(numel(subset)/opts.batchSize)) ;
  batchSize = min(opts.batchSize, numel(subset) - t + 1) ;
  numDone = 0 ;
  error = [] ;
  for s=1:opts.numSubBatches
    % get this image batch and prefetch the next
    batchStart = t + (labindex-1) + (s-1) * numlabs ;
    batchEnd = min(t+opts.batchSize-1, numel(subset)) ;
    batch = subset(batchStart : opts.numSubBatches * numlabs : batchEnd) ;
    [im, pcoords, labels, instanceWeights] = getBatch(imdb, batch) ;

    if opts.prefetch
      if s==opts.numSubBatches
        batchStart = t + (labindex-1) + opts.batchSize ;
        batchEnd = min(t+2*opts.batchSize-1, numel(subset)) ;
      else
        batchStart = batchStart + numlabs ;
      end
      nextBatch = subset(batchStart : opts.numSubBatches * numlabs : batchEnd) ;
      getBatch(imdb, nextBatch) ;
    end

    if numGpus >= 1
      im = gpuArray(im) ;
    end

    % evaluate the CNN
    net.layers{end}.opts=[];
    %Binary Labels
    if(size(net.layers{end-1}.weights{1},4)==1)
     net.layers{end}.opts.loss='logistic';%'hinge';
    %Category labels 
    else
        labels(labels>0)=2;
        labels(labels<0)=1;
        net.layers{end}.opts.loss='softmaxlog';
    end
    %Weights for AUC
    net.layers{end}.class = reshape(labels,[1 1 size(labels,1) size(labels,2)]) ;
    net.layers{end}.opts.instanceWeights=reshape(instanceWeights,[1 1 size(instanceWeights,1) size(instanceWeights,2)]);
     
    if training, dzdy = one; else, dzdy = [] ; end
    %First, execute the net_seg
    res_seg = vl_simplenn_mask(net_seg, im, pcoords, [], res_seg, ...
                      'accumulate', s ~= 1, ...
                      'mode', 'test', ...
                      'conserveMemory', opts.conserveMemory, ...
                      'backPropDepth', 0, ...
                      'sync', opts.sync, ...
                      'cudnn', opts.cudnn) ;
    %Quit background
    wmod=res_seg(end).x(:,:,2:end,:);
    %Reduce analysis to lession masks
    masks=pcoords(:,:,1,:)>0;
    masks = imresize(masks,[size(wmod,1) size(wmod,2)],'Method','nearest');
    wmod=bsxfun(@times,wmod,masks);
    
    
    res_seg=[];
    for l=1:length(net.layers)
        %In case of modulation, add the whole image
        if(strcmp(net.layers{l}.type,'modulateInputs'))
            %Sin máscara
            wmod = cat(3,ones(size(wmod,1),size(wmod,2),1,size(wmod,4),'single'),wmod);
            %Con máscara
%             wmod = cat(3,masks,wmod);
            net.layers{l}.wmod=wmod;
        elseif(strcmp(net.layers{l}.type,'fuseInputs'))
            net.layers{l}.wmod=wmod;
        end
    end
    clear wmod;
    
    res = vl_simplenn_mask(net, im, pcoords, dzdy, res, ...
                      'accumulate', s ~= 1, ...
                      'mode', evalMode, ...
                      'conserveMemory', opts.conserveMemory, ...
                      'backPropDepth', opts.backPropDepth, ...
                      'sync', opts.sync, ...
                      'cudnn', opts.cudnn) ;

    % accumulate training errors
    auxerr = opts.errorFunction(opts, labels, res);
    %AUC or AP
    if(isstruct(auxerr))
        opts.perf_data.labels=[opts.perf_data.labels;auxerr.labels];
        opts.perf_data.predictions=[opts.perf_data.predictions;auxerr.predictions];
        opts.perf_data.perf=[opts.perf_data.perf;auxerr.perf];
        mean_perf=opts.perf_data.perf(end,:);
%         error(2)=0;
        error = sum([error, [sum(double(gather(res(end).x))) ;reshape(mean(mean_perf),[],1) ; reshape(mean_perf,[],1) ]],2) ;
    else
        error = sum([error, [sum(double(gather(res(end).x))) ;reshape(auxerr,[],1) ; ]],2) ;
    end

    numDone = numDone + numel(batch) ;
  end % next sub-batch

  % gather and accumulate gradients across labs
  if training
    if numGpus <= 1
      [net,res] = accumulate_gradients(opts, learningRate, batchSize, net, res) ;
    else
      if isempty(mmap)
        mmap = map_gradients(opts.memoryMapFile, net, res, numGpus) ;
      end
      write_gradients(mmap, net, res) ;
      labBarrier() ;
      [net,res] = accumulate_gradients(opts, learningRate, batchSize, net, res, mmap) ;
    end
  end

  % collect and print learning statistics
  time = toc(start) ;
  stats = sum([stats,[0 ; error]],2); % works even when stats=[]
  
  stats(1) = time ;
  n = t + batchSize - 1 ; % number of images processed overall
  speed = n/time ;
  fprintf('%.1f Hz%s\n', speed) ;
    
  m = n / max(1,numlabs) ; % num images processed on this lab only
  %We set this error
  if(~isempty(opts.perf_data.perf))
      stats(3:end) = error(2:end)*m;
  end
  fprintf(' obj:%.3f', stats(2)/m) ;
  numExtraPerf=length(error)-2;
  %Printing average results
  for i=1:numel(opts.errorLabels)
    fprintf(' %s:%.3f', opts.errorLabels{i}, stats(i+2)/m) ;
    if(numExtraPerf>0)
        fprintf(' e-%s',opts.errorLabels{i});
        for j=1:numExtraPerf
            fprintf(' %.2f', stats(j+3)/m) ;
        end
    end
  end
  
  fprintf(' [%d/%d]', numDone, batchSize);
  fprintf('\n') ;

  % collect diagnostic statistics
  if training & opts.plotDiagnostics
    switchfigure(2) ; clf ;
    diag = [res.stats] ;
    barh(horzcat(diag.variation)) ;
    set(gca,'TickLabelInterpreter', 'none', ...
      'YTickLabel',horzcat(diag.label), ...
      'YDir', 'reverse', ...
      'XScale', 'log', ...
      'XLim', [1e-5 1]) ;
    drawnow ;
  end

end

% switch off the profiler
if opts.profile
  if numGpus <= 1
    prof = profile('info') ;
    profile off ;
  else
    prof = mpiprofile('info');
    mpiprofile off ;
  end
else
  prof = [] ;
end

% bring the network back to CPU
if numGpus >= 1
  net_cpu = vl_simplenn_move(net, 'cpu') ;
%   net_seg_cpu = vl_simplenn_move(net_seg_cpu, 'cpu') ;
else
  net_cpu = net ;
end
%Reseteamos la gpu
% wait(gpuDevice);
% reset(gpuDevice);
% keyboard;


% -------------------------------------------------------------------------
function [net,res] = accumulate_gradients(opts, lr, batchSize, net, res, mmap)
% -------------------------------------------------------------------------
if nargin >= 6
  numGpus = numel(mmap.Data) ;
else
  numGpus = 1 ;
end

for l=numel(net.layers):-1:1
  for j=1:numel(res(l).dzdw)
    if(net.layers{l}.learningRate(j)==0)
        break;
    end
        
    % accumualte gradients from multiple labs (GPUs) if needed
    if numGpus > 1
      tag = sprintf('l%d_%d',l,j) ;
      tmp = zeros(size(mmap.Data(labindex).(tag)), 'single') ;
      for g = setdiff(1:numGpus, labindex)
        tmp = tmp + mmap.Data(g).(tag) ;
      end
      res(l).dzdw{j} = res(l).dzdw{j} + tmp ;
    end

    if j == 3 && strcmp(net.layers{l}.type, 'bnorm')
      % special case for learning bnorm moments
      thisLR = net.layers{l}.learningRate(j) ;
      net.layers{l}.weights{j} = ...
        (1-thisLR) * net.layers{l}.weights{j} + ...
        (thisLR/batchSize) * res(l).dzdw{j} ;
    else
      % standard gradient training    
      thisDecay = opts.weightDecay * net.layers{l}.weightDecay(j) ;
      thisLR = lr * net.layers{l}.learningRate(j) ;
      net.layers{l}.momentum{j} = ...
        opts.momentum * net.layers{l}.momentum{j} ...
        - thisDecay * net.layers{l}.weights{j} ...
        - (1 / batchSize) * res(l).dzdw{j} ;
      net.layers{l}.weights{j} = net.layers{l}.weights{j} + ...
        thisLR * net.layers{l}.momentum{j} ;
    end

    % if requested, collect some useful stats for debugging
    if opts.plotDiagnostics
      variation = [] ;
      label = '' ;
      switch net.layers{l}.type
        case {'conv','convt'}
          variation = thisLR * mean(abs(net.layers{l}.momentum{j}(:))) ;
          if j == 1 % fiters
            base = mean(abs(net.layers{l}.weights{j}(:))) ;
            label = 'filters' ;
          else % biases
            base = mean(abs(res(l+1).x(:))) ;
            label = 'biases' ;
          end
          variation = variation / base ;
          label = sprintf('%s_%s', net.layers{l}.name, label) ;
      end
      res(l).stats.variation(j) = variation ;
      res(l).stats.label{j} = label ;
    end
  end
end

% -------------------------------------------------------------------------
function mmap = map_gradients(fname, net, res, numGpus)
% -------------------------------------------------------------------------
format = {} ;
for i=1:numel(net.layers)
  for j=1:numel(res(i).dzdw)
    format(end+1,1:3) = {'single', size(res(i).dzdw{j}), sprintf('l%d_%d',i,j)} ;
  end
end
format(end+1,1:3) = {'double', [3 1], 'errors'} ;
if ~exist(fname) && (labindex == 1)
  f = fopen(fname,'wb') ;
  for g=1:numGpus
    for i=1:size(format,1)
      fwrite(f,zeros(format{i,2},format{i,1}),format{i,1}) ;
    end
  end
  fclose(f) ;
end
labBarrier() ;
mmap = memmapfile(fname, 'Format', format, 'Repeat', numGpus, 'Writable', true) ;

% -------------------------------------------------------------------------
function write_gradients(mmap, net, res)
% -------------------------------------------------------------------------
for i=1:numel(net.layers)
  for j=1:numel(res(i).dzdw)
    mmap.Data(labindex).(sprintf('l%d_%d',i,j)) = gather(res(i).dzdw{j}) ;
  end
end

% -------------------------------------------------------------------------
function epoch = findLastCheckpoint(modelDir)
% -------------------------------------------------------------------------
list = dir(fullfile(modelDir, 'net-epoch-*.mat')) ;
tokens = regexp({list.name}, 'net-epoch-([\d]+).mat', 'tokens') ;
epoch = cellfun(@(x) sscanf(x{1}{1}, '%d'), tokens) ;
epoch = max([epoch 0]) ;

% -------------------------------------------------------------------------
function switchfigure(n)
% -------------------------------------------------------------------------
if get(0,'CurrentFigure') ~= n
  try
    set(0,'CurrentFigure',n) ;
  catch
    figure(n) ;
  end
end