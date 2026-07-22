#import <Foundation/Foundation.h>

static NSString *const AndroidVMName = @"Android-ARM64-SE.utm";
static NSString *const AndroidRuntimeVersion = @"aosp-fvp-arm64-se-v3-fvpbase-virtio-mmio";

__attribute__((constructor))
static void AndroidArm64GuestBootstrap(void) {
    @autoreleasepool {
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSString *homePath = NSProcessInfo.processInfo.environment[@"HOME"];
        if (homePath.length == 0) {
            NSLog(@"[AndroidArm64GuestBootstrap] HOME is unavailable.");
            return;
        }

        NSURL *sourceVM = [NSBundle.mainBundle.bundleURL
            URLByAppendingPathComponent:@"PreloadedData/Android-ARM64-SE.utm"
            isDirectory:YES];
        NSURL *documentsURL = [[NSURL fileURLWithPath:homePath isDirectory:YES]
            URLByAppendingPathComponent:@"Documents"
            isDirectory:YES];
        NSURL *destinationVM = [documentsURL URLByAppendingPathComponent:AndroidVMName isDirectory:YES];
        NSURL *markerURL = [destinationVM URLByAppendingPathComponent:@"AndroidArm64GuestBootstrap.plist"];

        NSDictionary *marker = [NSDictionary dictionaryWithContentsOfURL:markerURL];
        NSString *installedVersion = [marker[@"runtimeVersion"] isKindOfClass:NSString.class]
            ? marker[@"runtimeVersion"]
            : nil;

        NSError *error = nil;
        if ([fileManager fileExistsAtPath:destinationVM.path] &&
            ![installedVersion isEqualToString:AndroidRuntimeVersion]) {
            if (![fileManager removeItemAtURL:destinationVM error:&error]) {
                NSLog(@"[AndroidArm64GuestBootstrap] Failed to replace stale runtime: %@", error);
                return;
            }
        }

        if (![fileManager fileExistsAtPath:destinationVM.path]) {
            error = nil;
            if (![fileManager copyItemAtURL:sourceVM toURL:destinationVM error:&error]) {
                NSLog(@"[AndroidArm64GuestBootstrap] Failed to install ARM64 SE VM: %@", error);
                return;
            }
        }

        NSDictionary *newMarker = @{
            @"runtimeVersion": AndroidRuntimeVersion,
            @"architecture": @"aarch64",
            @"machine": @"virt,mte=on",
            @"androidTarget": @"fvpbase",
            @"executionMode": @"UTM SE interpreter",
            @"jitRequired": @NO,
            @"directKernelBoot": @YES,
            @"storageTransport": @"virtio-mmio",
            @"networkTransport": @"virtio-mmio",
            @"vm": AndroidVMName,
        };
        if (![newMarker writeToURL:markerURL atomically:YES]) {
            NSLog(@"[AndroidArm64GuestBootstrap] Failed to write runtime marker.");
            return;
        }
        NSLog(@"[AndroidArm64GuestBootstrap] No-JIT ARM64 Android VM ready at %@", destinationVM.path);
    }
}
