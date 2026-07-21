#import <Foundation/Foundation.h>

static NSString *const AndroidVMName = @"Android.utm";
static NSString *const AndroidISOName = @"android-x86_64-9.0-r2.iso";
static NSString *const AndroidDiskName = @"android-data.qcow2";

static BOOL AndroidCopyItemIfMissing(NSFileManager *fileManager, NSURL *source, NSURL *destination, NSError **error) {
    if ([fileManager fileExistsAtPath:destination.path]) {
        return YES;
    }
    if (![fileManager fileExistsAtPath:source.path]) {
        if (error) {
            *error = [NSError errorWithDomain:@"AndroidGuestBootstrap"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"Bundled file is missing: %@", source.path]}];
        }
        return NO;
    }
    return [fileManager copyItemAtURL:source toURL:destination error:error];
}

__attribute__((constructor))
static void AndroidGuestBootstrap(void) {
    @autoreleasepool {
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSString *homePath = NSProcessInfo.processInfo.environment[@"HOME"];
        if (homePath.length == 0) {
            NSLog(@"[AndroidGuestBootstrap] HOME is unavailable; LiveContainer did not initialize the guest container.");
            return;
        }

        NSURL *sourceVM = [NSBundle.mainBundle.bundleURL
            URLByAppendingPathComponent:@"PreloadedData/Android.utm"
            isDirectory:YES];
        NSURL *documentsURL = [[NSURL fileURLWithPath:homePath isDirectory:YES]
            URLByAppendingPathComponent:@"Documents"
            isDirectory:YES];
        NSURL *destinationVM = [documentsURL URLByAppendingPathComponent:AndroidVMName isDirectory:YES];
        NSURL *sourceImages = [sourceVM URLByAppendingPathComponent:@"Images" isDirectory:YES];
        NSURL *destinationImages = [destinationVM URLByAppendingPathComponent:@"Images" isDirectory:YES];

        NSError *error = nil;
        if (![fileManager createDirectoryAtURL:destinationImages
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&error]) {
            NSLog(@"[AndroidGuestBootstrap] Failed to create Android VM directory: %@", error);
            return;
        }

        NSURL *sourceConfig = [sourceVM URLByAppendingPathComponent:@"config.plist"];
        NSURL *destinationConfig = [destinationVM URLByAppendingPathComponent:@"config.plist"];
        if (!AndroidCopyItemIfMissing(fileManager, sourceConfig, destinationConfig, &error)) {
            NSLog(@"[AndroidGuestBootstrap] Failed to install VM configuration: %@", error);
            return;
        }

        NSURL *sourceDisk = [sourceImages URLByAppendingPathComponent:AndroidDiskName];
        NSURL *destinationDisk = [destinationImages URLByAppendingPathComponent:AndroidDiskName];
        error = nil;
        if (!AndroidCopyItemIfMissing(fileManager, sourceDisk, destinationDisk, &error)) {
            NSLog(@"[AndroidGuestBootstrap] Failed to install writable Android disk: %@", error);
            return;
        }

        NSURL *sourceISO = [sourceImages URLByAppendingPathComponent:AndroidISOName];
        NSURL *destinationISO = [destinationImages URLByAppendingPathComponent:AndroidISOName];
        if (![fileManager fileExistsAtPath:destinationISO.path]) {
            error = nil;
            if (![fileManager createSymbolicLinkAtURL:destinationISO
                                    withDestinationURL:sourceISO
                                                 error:&error]) {
                NSLog(@"[AndroidGuestBootstrap] Failed to link bundled Android ISO: %@", error);
                return;
            }
        }

        NSDictionary *marker = @{
            @"installed": @YES,
            @"sourceBundle": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
            @"vm": AndroidVMName,
            @"isoLinked": @YES
        };
        NSURL *markerURL = [destinationVM URLByAppendingPathComponent:@"AndroidGuestBootstrap.plist"];
        [marker writeToURL:markerURL atomically:YES];
        NSLog(@"[AndroidGuestBootstrap] Android VM is ready at %@", destinationVM.path);
    }
}
