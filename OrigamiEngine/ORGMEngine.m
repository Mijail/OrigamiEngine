//
// ORGMEngine.m
//
// Copyright (c) 2012 ap4y (lod@pisem.net)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "ORGMEngine.h"

#import "ORGMInputUnit.h"
#import "ORGMOutputUnit.h"
#import "ORGMConverter.h"
#import "ORGMCommonProtocols.h"

@interface ORGMEngine () <ORGMInputUnitDelegate,ORGMOutputUnitDelegate>

@property (strong, nonatomic) ORGMInputUnit *input;
@property (strong, nonatomic) ORGMOutputUnit *output;
@property (strong, nonatomic) ORGMConverter *converter;
@property (assign, nonatomic) ORGMEngineState currentState;
@property (strong, nonatomic) NSError *currentError;
@property (assign, nonatomic) float lastPreloadProgress;
//@property (strong, nonatomic) dispatch_queue_t callback_queue;
@property (strong, nonatomic) dispatch_queue_t processing_queue;
@property (strong, nonatomic) dispatch_source_t buffering_source;

@end

@implementation ORGMEngine

- (instancetype)init {
    self = [super init];
    if (self) {
        //self.callback_queue = dispatch_queue_create("com.origami.callback",DISPATCH_QUEUE_SERIAL);
        self.processing_queue = dispatch_queue_create("com.origami.processing",DISPATCH_QUEUE_SERIAL);
        self.buffering_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD,0, 0, self.processing_queue);
        dispatch_resume(self.buffering_source);
        self.volume = 100.0f;
        [self setup];
        _currentState = ORGMEngineStateStopped;
    }
    return self;
}

- (void)dealloc {
    self.delegate = nil;
    [self clearUnits];
    //self.callback_queue = nil;
    self.processing_queue = nil;
    self.buffering_source = nil;
}

- (void)setCurrentState:(ORGMEngineState)currentState{
    if(_currentState!=currentState){
        _currentState = currentState;
        __weak typeof (self) weakSelf = self;
        //dispatch_async(self.callback_queue, ^{
            if ([weakSelf.delegate respondsToSelector:@selector(engine:didChangeState:)]) {
                [weakSelf.delegate engine:weakSelf didChangeState:currentState];
            }
        //});
    }
}

#pragma mark - public

- (void)playUrl:(NSURL *)url withOutputUnitClass:(Class)outputUnitClass {
    NSAssert([outputUnitClass isSubclassOfClass:[ORGMOutputUnit class]], @"Output unit should be subclass of ORGMOutputUnit");
    [self clearUnits];
    self.currentError = nil;
    ORGMInputUnit *input = [[ORGMInputUnit alloc] init];
    self.input = input;
    self.input.inputUnitDelegate = self;
    if (NO==[self.input openWithUrl:url]) {
        self.currentState = ORGMEngineStateError;
        self.currentError = [NSError errorWithDomain:kErrorDomain
                                                code:ORGMEngineErrorCodesSourceFailed
                                            userInfo:@{ NSLocalizedDescriptionKey:
                                                        NSLocalizedString(@"Couldn't open source", nil) }];
        return;
    }
    [self.input addItemStatusObserver:self forKeyPaths:[NSSet setWithArray:@[@"endOfInput"]] options:NSKeyValueObservingOptionNew];
    ORGMConverter *converter = [[ORGMConverter alloc] initWithInputUnit:self.input bufferingSource:self.buffering_source];
    self.converter = converter;
    ORGMOutputUnit *output = [[outputUnitClass alloc] initWithConverter:self.converter];
    output.outputFormat = self.outputFormat;
    [self.output.converter.inputUnit removeItemStatusObserver];
    self.output = output;
    self.output.outputUnitDelegate = self;
    [self.output setVolume:self.volume];
    if (NO==[self.converter setupWithOutputUnit:self.output]) {
        self.currentState = ORGMEngineStateError;
        self.currentError = [NSError errorWithDomain:kErrorDomain
                                                code:ORGMEngineErrorCodesConverterFailed
                                            userInfo:@{ NSLocalizedDescriptionKey:
                                                        NSLocalizedString(@"Couldn't setup converter", nil) }];
        return;
    }
    __weak typeof (self) weakSelf = self;
    //dispatch_async(self.callback_queue, ^{
        if([weakSelf.delegate respondsToSelector:@selector(engine:didChangeCurrentURL:prevItemURL:)]) {
            [weakSelf.delegate engine:weakSelf didChangeCurrentURL:url prevItemURL:nil];
        }
    //});
    [self setCurrentState:ORGMEngineStatePlaying];
    dispatch_source_merge_data(self.buffering_source, 1);
}

- (void)playUrl:(NSURL *)url {
   [self playUrl:url withOutputUnitClass:[ORGMOutputUnit class]];
}

- (NSURL *)currentURL{
    return self.input.currentURL;
}

- (float)preloadProgress{
    return self.input.preloadProgress;
}

- (BOOL)isReadyToPlay{
    return self.output.isReadyToPlay;
}

- (void)pause {
    if (self.currentState != ORGMEngineStatePlaying){
        return;
    }
    [self.output pause];
    [self setCurrentState:ORGMEngineStatePaused];
}

- (void)resume {
    if (self.currentState != ORGMEngineStatePaused){
        return;
    }
    [self.output resume];
    [self setCurrentState:ORGMEngineStatePlaying];
}

- (void)clearUnits{
    self.input.inputUnitDelegate = nil;
    self.output.outputUnitDelegate = nil;
    [self.input removeItemStatusObserver];
    self.input = nil;
    self.output = nil;
    self.converter = nil;
}

- (void)stop {
    [self clearUnits];
    [self setCurrentState:ORGMEngineStateStopped];
}

- (double)trackTime {
    return [self.output framesToSeconds:self.input.framesCount];
}

- (double)amountPlayed {
    return [self.output amountPlayed];
}

- (NSDictionary *)metadata {
    return [self.input metadata];
}

- (void)seekToTime:(double)time withDataFlush:(BOOL)flush {
    [self.output seek:time];
    [self.input seek:time withDataFlush:flush];
    if (flush) {
        [self.converter flushBuffer];
    }
}

- (void)seekToTime:(double)time {
    [self seekToTime:time withDataFlush:NO];
}

- (void)setNextUrl:(NSURL *)url withDataFlush:(BOOL)flush {
    NSURL *prevURL = self.currentURL;
    if (!url) {
        [self stop];
    } else {
        if ([self.input openWithUrl:url]==NO) {
            self.currentState = ORGMEngineStateError;
            self.currentError = [NSError errorWithDomain:kErrorDomain
                                                    code:ORGMEngineErrorCodesSourceFailed
                                                userInfo:@{ NSLocalizedDescriptionKey:
                                                                NSLocalizedString(@"Couldn't open source", nil) }];
            [self stop];
        }
        else{
            [self.converter reinitWithNewInput:self.input withDataFlush:flush];
            [self.output seek:0.0]; //to reset amount played
             __weak typeof (self) weakSelf = self;
            //dispatch_async(self.callback_queue, ^{
                if([weakSelf.delegate respondsToSelector:@selector(engine:didChangeCurrentURL:prevItemURL:)]) {
                    [weakSelf.delegate engine:weakSelf didChangeCurrentURL:url prevItemURL:prevURL];
                }
            //});
            [self setCurrentState:ORGMEngineStatePlaying]; //trigger delegate method
        }
    }
}

#pragma mark - private

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
     if ([keyPath isEqualToString:@"endOfInput"]) {
        NSURL *nextUrl = nil;
        if([self.delegate respondsToSelector:@selector(engineExpectsNextUrl:)]){
             nextUrl = [self.delegate engineExpectsNextUrl:self];
        }
        if (nextUrl==nil) {
            [self stop];
        }
        else{
            [self setNextUrl:nextUrl withDataFlush:NO];
        }
    }
}

- (void)setup {
    __weak typeof (self) weakSelf = self;
    dispatch_source_set_event_handler(self.buffering_source, ^{
        [weakSelf.input process];
        [weakSelf.converter process];
    });
}

- (void)setVolume:(float)volume {
    _volume = volume;
    [self.output setVolume:volume];
}

- (void)inputUnit:(ORGMInputUnit *)unit didChangePreloadProgress:(float)progress{
    if( unit==self.input && (ABS(_lastPreloadProgress-progress)>0.05 || (fabs(progress - 1.0) < FLT_EPSILON) || (fabs(progress) < FLT_EPSILON))){
        _lastPreloadProgress = progress;
        __weak typeof (self) weakSelf = self;
        //dispatch_async(self.callback_queue, ^{
            if([weakSelf.delegate respondsToSelector:@selector(engine:didChangePreloadProgress:)]){
                [weakSelf.delegate engine:weakSelf didChangePreloadProgress:progress];
            }
        //});
    }
}

- (void)inputUnit:(ORGMInputUnit *)unit didFailWithError:(NSError *)error{
    if(unit==self.input){
        __weak typeof (self) weakSelf = self;
        //dispatch_async(self.callback_queue, ^{
            if([weakSelf.delegate respondsToSelector:@selector(engine:didFailCurrentItemWithError:)]){
                [weakSelf.delegate engine:weakSelf didFailCurrentItemWithError:error];
            }
        //});
    }
}

- (void)outputUnit:(ORGMOutputUnit *)unit didChangeReadyToPlay:(BOOL)readyToPlay{
    if(unit==self.output){
        __weak typeof (self) weakSelf = self;
        //dispatch_async(self.callback_queue, ^{
            if([weakSelf.delegate respondsToSelector:@selector(engine:didChangeReadyToPlay:)]){
                [weakSelf.delegate engine:weakSelf didChangeReadyToPlay:readyToPlay];
            }
        //});
    }
}

@end
