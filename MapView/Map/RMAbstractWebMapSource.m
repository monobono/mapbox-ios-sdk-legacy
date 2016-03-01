//
// RMAbstractWebMapSource.m
//
// Copyright (c) 2008-2013, Route-Me Contributors
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#import "RMAbstractWebMapSource.h"

#import "RMTileCache.h"
#import "RMConfiguration.h"

#import "RMTileCacheDownloadOperation.h"

#define HTTP_404_NOT_FOUND 404

static NSString * KeyForTile(RMTile tile) {
    return [NSString stringWithFormat:@"%hd|%u|%u", tile.zoom, tile.x, tile.y];
}

static RMTile TileFromKey(NSString *key) {
    NSArray *components = [key componentsSeparatedByString:@"|"];
    short zoom = [components[0] integerValue];
    uint32_t x = [components[1] integerValue];
    uint32_t y = [components[2] integerValue];
    return RMTileMake(x, y, zoom);
}

@implementation RMAbstractWebMapSource {
    NSMapTable *_initiatedTasks;
    NSURLSession *_URLSession;
}

@synthesize retryCount, requestTimeoutSeconds;

- (instancetype)init
{
    if (!(self = [super init]))
        return nil;

    self.retryCount = RMAbstractWebMapSourceDefaultRetryCount;
    self.requestTimeoutSeconds = RMAbstractWebMapSourceDefaultWaitSeconds;
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.HTTPShouldUsePipelining = YES;
    
    _URLSession = [NSURLSession sessionWithConfiguration:config];
    _initiatedTasks = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsCopyIn valueOptions:NSPointerFunctionsWeakMemory capacity:64];
    return self;
}

- (void)cancelAllDownloads
{
    NSArray *tasks = nil;
    
    @synchronized(_initiatedTasks) {
        tasks = [_initiatedTasks.objectEnumerator.allObjects copy];
    }
    
    for (NSURLSessionDataTask *task in tasks) {
        [task cancel];
    }
}

- (BOOL)operationExistsForTile:(RMTile)tile
{
    BOOL exists = NO;
    
    @synchronized(_initiatedTasks) {
        NSURLSessionTask *task = [_initiatedTasks objectForKey:KeyForTile(tile)];
        exists = task != NULL && task.state != NSURLSessionTaskStateCanceling;
    }
    
    return exists;
}

- (void)cancelDownloadsIrrelevantToTile:(RMTile)tile visibleMapRect:(RMIntegralRect)mapRect
{
    @synchronized(_initiatedTasks) {
        for (NSString *key in _initiatedTasks.keyEnumerator.allObjects) {
            NSURLSessionTask *task = [_initiatedTasks objectForKey:key];
            if (task.state == NSURLSessionTaskStateCanceling) {
                continue;
            }
            
            RMTile taskTile = TileFromKey(key);
            if (taskTile.zoom != tile.zoom) {
                [task cancel];
            } else if (!RMIntegralRectContainsPoint(mapRect, RMIntegralPointMake(taskTile.x, taskTile.y))){
                [task cancel];
            }
        }
    }
}

- (void)registerTask:(NSURLSessionDataTask *)task forTile:(RMTile)tile
{
    @synchronized(_initiatedTasks) {
        [_initiatedTasks setObject:task forKey:KeyForTile(tile)];
    }
}

- (void)downloadImageForTile:(RMTile)tile cache:(RMTileCache *)cache visibleMapRect:(RMIntegralRect)mapRect completion:(void (^)(void))completion
{
    if ([self operationExistsForTile:tile]) {
        return;
    }
    
    [self cancelDownloadsIrrelevantToTile:tile visibleMapRect:mapRect];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:RMTileRequested object:[NSNumber numberWithUnsignedLongLong:RMTileKey(tile)]];
    });
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self URLForTile:tile]];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = [self requestTimeoutSeconds];
    [request setValue:[[RMConfiguration sharedInstance] userAgent] forHTTPHeaderField:@"User-Agent"];
    
    NSURLSessionDataTask *task = [_URLSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (statusCode == 200 && error == nil) {
            [cache addImage:[UIImage imageWithData:data] forTile:tile withCacheKey:[self uniqueTilecacheKey]];
            
            dispatch_async(dispatch_get_main_queue(), ^{
               [[NSNotificationCenter defaultCenter] postNotificationName:RMTileRetrieved object:[NSNumber numberWithUnsignedLongLong:RMTileKey(tile)]];
            });
        }
        
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    }];
    [task resume];
    [self registerTask:task forTile:tile];
}

- (NSURL *)URLForTile:(RMTile)tile
{
    @throw [NSException exceptionWithName:@"RMAbstractMethodInvocation"
                                   reason:@"URLForTile: invoked on RMAbstractWebMapSource. Override this method when instantiating an abstract class."
                                 userInfo:nil];
}

- (NSArray *)URLsForTile:(RMTile)tile
{
    return [NSArray arrayWithObjects:[self URLForTile:tile], nil];
}

- (UIImage *)imageForTile:(RMTile)tile inCache:(RMTileCache *)tileCache
{
    // This method only considers the cache. Use downloadImageForTile: to download a
    // tile nonexistant in the cache.
    return [tileCache cachedImage:tile withCacheKey:[self uniqueTilecacheKey]];
}

@end
