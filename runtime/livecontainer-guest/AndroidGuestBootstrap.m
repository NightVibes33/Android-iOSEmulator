#import <Foundation/Foundation.h>

static NSString *const AndroidVMName = @"Android.utm";
static NSString *const AndroidDiskName = @"bliss-android13-preinstalled.qcow2";
static NSString *const AndroidRuntimeVersion = @"bliss16-android13-v2-graphics-handoff";

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

static BOOL AndroidReplaceFile(NSFileManager *fileManager, NSURL *source, NSURL *destination, NSError **error) {
    if ([fileManager fileExistsAtPath:destination.path] &&
        ![fileManager removeItemAtURL:destination error:error]) {
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
        NSURL *markerURL = [destinationVM URLByAppendingPathComponent:@"AndroidGuestBootstrap.plist"];

        NSDictionary *existingMarker = [NSDictionary dictionaryWithContentsOfURL:markerURL];
        NSString *existingVersion = [existingMarker[@"runtimeVersion"] isKindOfClass:NSString.class]
            ? existingMarker[@"runtimeVersion"]
            : nil;

        NSError *error = nil;
        if ([fileManager fileExistsAtPath:destinationVM.path] &&
            ![existingVersion isEqualToString:AndroidRuntimeVersion]) {
            NSLog(@"[AndroidGuestBootstrap] Replacing the old Android runtime (%@) with %@.",
                  existingVersion ?: @"legacy", AndroidRuntimeVersion);
            if (![fileManager removeItemAtURL:destinationVM error:&error]) {
                NSLog(@"[AndroidGuestBootstrap] Failed to remove the old Android VM: %@", error);
                return;
            }
        }

        error = nil;
        if (![fileManager createDirectoryAtURL:destinationImages
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&error]) {
            NSLog(@"[AndroidGuestBootstrap] Failed to create Android VM directory: %@", error);
            return;
        }

        NSURL *sourceConfig = [sourceVM URLByAppendingPathComponent:@"config.plist"];
        NSURL *destinationConfig = [destinationVM URLByAppendingPathComponent:@"config.plist"];
        error = nil;
        if (!AndroidReplaceFile(fileManager, sourceConfig, destinationConfig, &error)) {
            NSLog(@"[AndroidGuestBootstrap] Failed to install Android 13 VM configuration: %@", error);
            return;
        }

        NSURL *sourceDisk = [sourceImages URLByAppendingPathComponent:AndroidDiskName];
        NSURL *destinationDisk = [destinationImages URLByAppendingPathComponent:AndroidDiskName];
        error = nil;
        if (!AndroidCopyItemIfMissing(fileManager, sourceDisk, destinationDisk, &error)) {
            NSLog(@"[AndroidGuestBootstrap] Failed to install the preinstalled Android 13 disk: %@", error);
            return;
        }

        NSDictionary *marker = @{
            @"installed": @YES,
            @"runtimeVersion": AndroidRuntimeVersion,
            @"androidVersion": @"13",
            @"distribution": @"BlissOS 16",
            @"sourceBundle": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
            @"vm": AndroidVMName,
            @"installerISO": @NO,
            @"preinstalledDisk": @YES
        };
        if (![marker writeToURL:markerURL atomically:YES]) {
            NSLog(@"[AndroidGuestBootstrap] Failed to write the Android runtime marker.");
            return;
        }
        NSLog(@"[AndroidGuestBootstrap] Preinstalled Android 13 VM is ready at %@", destinationVM.path);
    }
}
