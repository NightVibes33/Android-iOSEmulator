#import <Foundation/Foundation.h>

static NSString *const AndroidVMName = @"Android-Redroid-ARM64-SE.utm";
static NSString *const AndroidRuntimeVersion = @"redroid13-arm64-se-v2-pinned-ci-boot";

__attribute__((constructor))
static void AndroidRedroidGuestBootstrap(void) {
    @autoreleasepool {
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSString *homePath = NSProcessInfo.processInfo.environment[@"HOME"];
        if (homePath.length == 0) {
            NSLog(@"[AndroidRedroidGuestBootstrap] HOME is unavailable.");
            return;
        }

        NSURL *sourceVM = [NSBundle.mainBundle.bundleURL
            URLByAppendingPathComponent:@"PreloadedData/Android-Redroid-ARM64-SE.utm"
            isDirectory:YES];
        NSURL *documentsURL = [[NSURL fileURLWithPath:homePath isDirectory:YES]
            URLByAppendingPathComponent:@"Documents"
            isDirectory:YES];
        NSURL *destinationVM = [documentsURL URLByAppendingPathComponent:AndroidVMName isDirectory:YES];
        NSURL *markerURL = [destinationVM URLByAppendingPathComponent:@"AndroidRedroidGuestBootstrap.plist"];

        NSDictionary *marker = [NSDictionary dictionaryWithContentsOfURL:markerURL];
        NSString *installedVersion = [marker[@"runtimeVersion"] isKindOfClass:NSString.class]
            ? marker[@"runtimeVersion"]
            : nil;

        NSError *error = nil;
        if ([fileManager fileExistsAtPath:destinationVM.path] &&
            ![installedVersion isEqualToString:AndroidRuntimeVersion]) {
            if (![fileManager removeItemAtURL:destinationVM error:&error]) {
                NSLog(@"[AndroidRedroidGuestBootstrap] Failed to replace stale runtime: %@", error);
                return;
            }
        }

        if (![fileManager fileExistsAtPath:destinationVM.path]) {
            error = nil;
            if (![fileManager copyItemAtURL:sourceVM toURL:destinationVM error:&error]) {
                NSLog(@"[AndroidRedroidGuestBootstrap] Failed to install ARM64 Redroid VM: %@", error);
                return;
            }
        }

        NSDictionary *newMarker = @{
            @"runtimeVersion": AndroidRuntimeVersion,
            @"architecture": @"aarch64",
            @"executionMode": @"UTM SE interpreter",
            @"jitRequired": @NO,
            @"androidRuntime": @"Redroid 13 64-bit only",
            @"redroidImage": @"13.0.0_64only-240527",
            @"hostBootconfigMasked": @YES,
            @"binderfsRequired": @YES,
            @"dmaBufSystemHeapRequired": @YES,
            @"ciAndroidBootRequired": @YES,
            @"vm": AndroidVMName,
        };
        if (![newMarker writeToURL:markerURL atomically:YES]) {
            NSLog(@"[AndroidRedroidGuestBootstrap] Failed to write runtime marker.");
            return;
        }
        NSLog(@"[AndroidRedroidGuestBootstrap] ARM64 no-JIT Android VM ready at %@", destinationVM.path);
    }
}
