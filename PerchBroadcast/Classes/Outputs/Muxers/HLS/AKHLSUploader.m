//
//  AKHLSUploader.m
//  Pods
//
//  Created by AK on 16/12/2016.
//
//

#import "AKHLSUploader.h"

#import "KFS3Stream.h"
#import "KFLog.h"
#import "KFAWSCredentialsProvider.h"
#import "KFHLSWriter.h"
#import "KFRecorder.h"
#import <AWSS3/AWSS3.h>

static NSString * const kManifestKey =  @"manifest";
static NSString * const kFileNameKey = @"fileName";
static NSString * const kDurationKey = @"duration";
static NSString * const kUploadStatusKey = @"status";
static NSString * const kFileStartDateKey = @"startDate";

static NSString * const kLiveManifestFileName = @"index.m3u8";
static NSString * const kVODManifestFileName = @"vod.m3u8";
static NSString * const kMasterManifestFileName = @"playlist.m3u8";

static NSString * const kUploadStateQueued = @"queued";
static NSString * const kUploadStateFinished = @"finished";
static NSString * const kUploadStateUploading = @"uploading";
static NSString * const kUploadStateFailed = @"failed";

static NSString * const kKFS3TransferManagerKey = @"kKFS3TransferManagerKey";
static NSString * const kKFS3Key = @"kKFS3Key";


@interface AKHLSManifest : NSObject
    @property (nonatomic) NSInteger version;
    @property (nonatomic) NSInteger targetDuration;
    @property (nonatomic) NSInteger mediaSequence;
    @property (nonatomic) BOOL finished;
    @property (nonatomic, strong) NSMutableArray* segments;
@end

@implementation AKHLSManifest

- (instancetype)initWithString:(NSString*) string
{
    self = [super init];
    if (self) {
        self.segments = [NSMutableArray array];
        NSArray* parts = [string componentsSeparatedByString:@"#EXTINF:"];
        
        NSArray* headers = [parts[0] componentsSeparatedByString:@"\n"];
        
        for (NSString* h in headers) {
            if ([h hasPrefix:@"#EXT-X-VERSION:"]) {
                self.version = [h componentsSeparatedByString:@":"][1].integerValue;
            }
            
            if ([h hasPrefix:@"#EXT-X-TARGETDURATION:"]) {
                self.targetDuration = [h componentsSeparatedByString:@":"][1].integerValue;
            }

            if ([h hasPrefix:@"#EXT-X-MEDIA-SEQUENCE:"]) {
                self.mediaSequence = [h componentsSeparatedByString:@":"][1].integerValue;
            }
        }
        
        for (NSInteger i = 1; i<parts.count; i++) {
            NSArray* info = [[parts[i] stringByReplacingOccurrencesOfString:@"\n" withString:@""] componentsSeparatedByString:@","];
            [self.segments addObject:@{kFileNameKey: info[1], kDurationKey: info[0] }];
        }
    }
    return self;
}

- (NSString*) toString {
    NSMutableString* res = [[NSMutableString alloc] initWithCapacity:10000];
    [res appendFormat:@"#EXTM3U\n#EXT-X-VERSION:%d\n", self.version];
    [res appendFormat:@"#EXT-X-TARGETDURATION:%d\n", self.targetDuration];
    [res appendFormat:@"#EXT-X-MEDIA-SEQUENCE:%d\n", self.mediaSequence];
    
    for (NSDictionary* s in self.segments) {
        [res appendFormat:@"#EXTINF:%@,\n%@\n", [s objectForKey:kDurationKey], [s objectForKey:kFileNameKey]];
    }
    
    if (_finished) {
        [res appendString:@"#EXT-X-ENDLIST\n"];
    }
    
    return res;
}

- (void) appendSegmentsFromString: (NSString*) string {
    NSArray* parts = [string componentsSeparatedByString:@"#EXTINF:"];
    
    NSArray* headers = [parts[0] componentsSeparatedByString:@"\n"];
    
    for (NSString* h in headers) {
        /*if ([h hasPrefix:@"#EXT-X-VERSION:"]) {
            self.version = [h componentsSeparatedByString:@":"][1].integerValue;
        }*/
        
        if ([h hasPrefix:@"#EXT-X-TARGETDURATION:"]) {
            NSInteger nd = [h componentsSeparatedByString:@":"][1].integerValue;
            
            if (self.targetDuration < nd)
                self.targetDuration = nd;
        }
        
        /*if ([h hasPrefix:@"#EXT-X-MEDIA-SEQUENCE:"]) {
            self.mediaSequence = [h componentsSeparatedByString:@":"][1].integerValue;
        }*/
    }
    
    for (NSInteger i = 1; i<parts.count; i++) {
        NSArray* info = [[parts[i] stringByReplacingOccurrencesOfString:@"\n" withString:@""] componentsSeparatedByString:@","];
        if (![self segmentsContainSegment:info[1]])
            [self.segments addObject:@{kFileNameKey: info[1], kDurationKey: info[0] }];
    }
}

- (BOOL) segmentsContainSegment: (NSString*) fileName {
    for (NSDictionary* s in self.segments) {
        if ([s objectForKey:kFileNameKey] == fileName)
            return YES;
    }
    
    return NO;
}

- (NSString*) nextSegmentToUpload {
    for (NSDictionary* s in self.segments) {
        if ([s objectForKey:kUploadStatusKey] == kUploadStateUploading)
            return nil;
    }
    
    for (NSDictionary* s in self.segments) {
        if (/*[s objectForKey:kUploadStatusKey] != kUploadStateUploading && */[s objectForKey:kUploadStatusKey] != kUploadStateFinished)
            return [s objectForKey:kFileNameKey];
    }
    
    return nil;
}

-(void) updateSegmentStatus:(NSString*)fileName status: (NSString*) status {
    for (NSInteger i = 0; i<self.segments.count; i++) {
        NSDictionary* s = self.segments[i];
        if ([s objectForKey:kFileNameKey] == fileName) {
            NSMutableDictionary* d = [NSMutableDictionary dictionaryWithDictionary:s];
            [d setValue:status forKey:kUploadStatusKey];
            [self.segments replaceObjectAtIndex:i withObject:d];
            return;
        }
    }
}

-(BOOL) readyToUploadManifest {
    for (NSDictionary* s in self.segments) {
        if ([s objectForKey:kUploadStatusKey] == kUploadStateFinished)
            return YES;
    }
    
    return NO;
}

@end

@interface AKHLSUploader()
@property (nonatomic, strong) AWSS3TransferManager *transferManager;
@property (nonatomic, strong) AWSS3 *s3;
@property (nonatomic, strong) KFDirectoryWatcher *directoryWatcher;

@property (nonatomic, strong) AKHLSManifest *liveManifest;

@end

@implementation AKHLSUploader

- (id) initWithDirectoryPath:(NSString *)directoryPath stream:(id<BroadcastStream>)stream {
    if (self = [super init]) {
        self.stream = stream;
        _directoryPath = [directoryPath copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.directoryWatcher = [KFDirectoryWatcher watchFolderWithPath:_directoryPath delegate:self];
        });
        //_files = [NSMutableDictionary dictionary];
        _scanningQueue = dispatch_queue_create("AKHLSUploader Scanning Queue", DISPATCH_QUEUE_SERIAL);
        _callbackQueue = dispatch_queue_create("AKHLSUploader Callback Queue", DISPATCH_QUEUE_SERIAL);
        //_queuedSegments = [NSMutableDictionary dictionaryWithCapacity:5];
        //_numbersOffset = 0;
        //_nextSegmentIndexToUpload = 0;
        //_manifestReady = NO;
        //_isFinishedRecording = NO;
        //_uploadRateTotal = 0;
        //_uploadRateCount = 0;
        
        if ([stream/*.endpoint*/ conformsToProtocol:@protocol(BroadcastS3Endpoint)]) {
            id<BroadcastS3Endpoint> s3Endpoint = (id<BroadcastS3Endpoint>)stream;//.endpoint;
            AWSRegionType region = [KFAWSCredentialsProvider regionTypeForRegion:s3Endpoint.awsRegion];
            KFAWSCredentialsProvider *awsCredentialsProvider = [[KFAWSCredentialsProvider alloc] initWithEndpoint:s3Endpoint];
            AWSServiceConfiguration *configuration = [[AWSServiceConfiguration alloc] initWithRegion:region
                                                                                 credentialsProvider:awsCredentialsProvider];
            
            [AWSS3TransferManager registerS3TransferManagerWithConfiguration:configuration forKey:kKFS3TransferManagerKey];
            [AWSS3 registerS3WithConfiguration:configuration forKey:kKFS3Key];
            
            self.transferManager = [AWSS3TransferManager S3TransferManagerForKey:kKFS3TransferManagerKey];
            self.s3 = [AWSS3 S3ForKey:kKFS3Key];
            
            
        } else {
            NSAssert(NO, @"Only S3 uploads are supported at this time");
        }
        
        
    }
    return self;
}

- (void) directoryDidChange:(KFDirectoryWatcher *)folderWatcher {
    dispatch_async(_scanningQueue, ^{
        NSString* content = [NSString stringWithContentsOfFile:[_directoryPath stringByAppendingPathComponent:@"index.m3u8"]
                                                      encoding:NSUTF8StringEncoding
                                                         error:NULL];
        
        if (content) {
            if (!_liveManifest)
                _liveManifest = [[AKHLSManifest alloc] initWithString:content];
            else
                [_liveManifest appendSegmentsFromString:content];
            
            NSString* ss = [_liveManifest toString];
            NSLog(ss);
        }
        
        NSString* fileName = [_liveManifest nextSegmentToUpload];
        if (fileName) {
            [self uploadNextSegment:fileName];
        }
        
    });
}

- (void) uploadNextSegment:(NSString*) fileName {
    /*NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.directoryPath error:nil];
    NSUInteger tsFileCount = 0;
    for (NSString *fileName in contents) {
        if ([[fileName pathExtension] isEqualToString:@"ts"]) {
            tsFileCount++;
        }
    }
    
    DDLogDebug(@"Attempting to queue next segment... %lld", _nextSegmentIndexToUpload);
    NSMutableDictionary *segmentInfo = [_queuedSegments objectForKey:@(_nextSegmentIndexToUpload)];
    NSString *fileName = [segmentInfo objectForKey:kFileNameKey];
    NSString *fileUploadState = [_files objectForKey:fileName];
    
    // Skip uploading files that are currently being written
    if (tsFileCount == 1 && !self.isFinishedRecording) {
        DDLogDebug(@"Skipping upload of ts file currently being recorded... %@", fileName);
        return;
    }
    
    if (![fileUploadState isEqualToString:kUploadStateQueued]) {
        DDLogDebug(@"Trying to upload file that isn't queued (is currently %@)... %@", fileUploadState, fileName);
        return;
    }
    
    [_files setObject:kUploadStateUploading forKey:fileName];*/
    
    NSLog(@"Uploading: %@", fileName);
    
    [_liveManifest updateSegmentStatus:fileName status:kUploadStateUploading];
    
    NSString *filePath = [_directoryPath stringByAppendingPathComponent:fileName];
    id<BroadcastS3Endpoint> s3Endpoint = (id<BroadcastS3Endpoint>)self.stream;//.endpoint;
    NSString *key = [self awsKeyForStream:self.stream fileName:fileName];
    
    AWSS3TransferManagerUploadRequest *uploadRequest = [AWSS3TransferManagerUploadRequest new];
    uploadRequest.bucket = s3Endpoint.bucketName;
    uploadRequest.key = key;
    uploadRequest.body = [NSURL fileURLWithPath:filePath];
    uploadRequest.ACL = AWSS3ObjectCannedACLPublicRead;
    uploadRequest.contentType = @"video/MP2T";
    
    /*__block NSDate *startUploadDate;
    uploadRequest.uploadProgress = ^(int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
        NSUInteger queuedSegmentsCount = _queuedSegments.count;
        
        if (bytesSent == totalBytesSent) {
            startUploadDate = [NSDate date];
            _uploadRateTotal = 0;
            _uploadRateCount = 0;
        } else {
            NSTimeInterval timeToUpload = [[NSDate date] timeIntervalSinceDate:startUploadDate];
            double bitsPerSecond = (totalBytesSent / timeToUpload) * 8;
            double kbps = bitsPerSecond / 1024;
            
            _uploadRateTotal += kbps;
            _uploadRateCount += 1;
            double averageUploadSpeed = _uploadRateTotal / _uploadRateCount;
            
            DDLogVerbose(@"Speed: %f kbps Average Speed: %f bytesSent: %d", kbps, averageUploadSpeed, bytesSent);
            
            if ([self.delegate respondsToSelector:@selector(uploader:didUploadPartOfASegmentAtUploadSpeed:)]) {
                //[self.delegate uploader:self didUploadPartOfASegmentAtUploadSpeed:kbps];
            }
        }
    };
    
    // Set the 'uploadStartDate' here, just before being added to the queue, instead of where the segmentInfo is created
    // Gives more accurate upload speed readings
    [segmentInfo setObject:[NSDate date] forKey:kFileStartDateKey];
    
    DDLogDebug(@"Queueing ts... %@", fileName);*/
    
    [[self.transferManager upload:uploadRequest] continueWithBlock:^id(AWSTask *task) {
        if (task.error) {
            //[self s3RequestFailedForFileName:fileName withError:task.error];
            NSLog(@"Failed: %@", fileName);
            [_liveManifest updateSegmentStatus:fileName status:kUploadStateFailed];
        } else {
            //[self s3RequestCompletedForFileName:fileName];
            
            NSLog(@"Uploaded: %@", fileName);
            
            [_liveManifest updateSegmentStatus:fileName status:kUploadStateFinished];
            
            NSString* nextFileName = [_liveManifest nextSegmentToUpload];
            if (nextFileName) {
                [self uploadNextSegment:nextFileName];
            }
            
            [self updateRemoteManifestWithString:[_liveManifest toString] manifestName:kLiveManifestFileName];
        }
        return nil;
    }];
    
}

- (void) updateRemoteManifestWithString:(NSString*)manifestString manifestName:(NSString*)manifestName {
    NSData *data = [manifestString dataUsingEncoding:NSUTF8StringEncoding];
    //DDLogVerbose(@"New manifest:\n%@", manifestString);
    NSString *key = [self awsKeyForStream:self.stream fileName:manifestName];
    
    id<BroadcastS3Endpoint> s3Endpoint = (id<BroadcastS3Endpoint>)self.stream;//.endpoint;
    AWSS3PutObjectRequest *uploadRequest = [AWSS3TransferManagerUploadRequest new];
    uploadRequest.bucket = s3Endpoint.bucketName;
    uploadRequest.key = key;
    uploadRequest.body = data;
    uploadRequest.ACL = AWSS3ObjectCannedACLPublicRead;
    uploadRequest.cacheControl = @"max-age=0";
    uploadRequest.contentType = @"application/x-mpegURL";
    uploadRequest.contentLength = @(data.length);
    //DDLogDebug(@"Queueing manifest... %@", manifestName);
    [[self.s3 putObject:uploadRequest] continueWithBlock:^id(AWSTask *task) {
        if (task.error) {
            //[self s3RequestFailedForFileName:manifestName withError:task.error];
            NSLog(@"Failed: %@", manifestName);
        } else {
            //[self s3RequestCompletedForFileName:manifestName];
            NSLog(@"Uploaded: %@", manifestName);
        }
        return nil;
    }];
}

- (NSString*) awsKeyForStream:(id<BroadcastStream>)stream fileName:(NSString*)fileName {
    if ([stream/*.endpoint*/ conformsToProtocol:@protocol(BroadcastS3Endpoint)]) {
        id<BroadcastS3Endpoint> s3Endpoint = (id<BroadcastS3Endpoint>)stream;//.endpoint;
        return [NSString stringWithFormat:@"%@%@", s3Endpoint.awsPrefix, fileName];
    } else {
        NSAssert(NO, @"unsupported endpoint type");
    }
    return nil;
}

@end
