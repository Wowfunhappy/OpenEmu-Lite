#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
#import <QuickLook/QuickLook.h>
#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *OE_md5ForFileAtURL(NSURL *url);
static NSImage *OE_screenshotForROMAtURL(NSURL *romURL);
static NSImage *OE_consoleImageForExtension(NSString *ext);
static void OE_drawThumbnailWithScreenshot(NSImage *screenshot, NSImage *consoleImage, CGContextRef cgContext, CGSize size);

void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail);
OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize);

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview);
OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options);

#pragma mark - MD5 Hashing

static NSString *OE_md5ForFileAtURL(NSURL *url)
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if(!handle) return nil;

    CC_MD5_CTX ctx;
    CC_MD5_Init(&ctx);

    while(YES) {
        @autoreleasepool {
            NSData *data = [handle readDataOfLength:32768];
            if(!data || [data length] == 0) break;
            CC_MD5_Update(&ctx, [data bytes], (CC_LONG)[data length]);
        }
    }
    [handle closeFile];

    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5_Final(digest, &ctx);

    return [NSString stringWithFormat:
        @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
        digest[0],  digest[1],  digest[2],  digest[3],
        digest[4],  digest[5],  digest[6],  digest[7],
        digest[8],  digest[9],  digest[10], digest[11],
        digest[12], digest[13], digest[14], digest[15]];
}

#pragma mark - NDS Icon Extraction

static NSImage *OE_iconFromNDSROM(NSURL *romURL)
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:romURL error:nil];
    if(!handle) return nil;

    // Read icon/title offset from NDS header at 0x68
    [handle seekToFileOffset:0x68];
    NSData *offsetData = [handle readDataOfLength:4];
    if([offsetData length] < 4) { [handle closeFile]; return nil; }

    uint32_t bannerOffset = *(const uint32_t *)[offsetData bytes];
    if(bannerOffset == 0) { [handle closeFile]; return nil; }

    // Read banner: skip 32 bytes header, then 512 bytes tile data + 32 bytes palette
    [handle seekToFileOffset:bannerOffset + 0x20];
    NSData *tileData = [handle readDataOfLength:512];
    NSData *paletteData = [handle readDataOfLength:32];
    [handle closeFile];

    if([tileData length] < 512 || [paletteData length] < 32) return nil;

    const uint8_t *tiles = [tileData bytes];
    const uint16_t *palette = [paletteData bytes];

    // Decode 32x32 icon from 4x4 grid of 8x8 tiles, 4bpp indexed color
    uint8_t pixels[32 * 32 * 4]; // RGBA
    memset(pixels, 0, sizeof(pixels));

    for(int tileY = 0; tileY < 4; tileY++) {
        for(int tileX = 0; tileX < 4; tileX++) {
            int tileIdx = tileY * 4 + tileX;
            const uint8_t *tileBytes = tiles + tileIdx * 32;

            for(int py = 0; py < 8; py++) {
                for(int px = 0; px < 8; px += 2) {
                    uint8_t byte = tileBytes[py * 4 + px / 2];
                    uint8_t idx0 = byte & 0x0F;
                    uint8_t idx1 = (byte >> 4) & 0x0F;

                    int x0 = tileX * 8 + px;
                    int y0 = tileY * 8 + py;
                    int x1 = x0 + 1;

                    for(int pass = 0; pass < 2; pass++) {
                        uint8_t idx = (pass == 0) ? idx0 : idx1;
                        int x = (pass == 0) ? x0 : x1;
                        int offset = (y0 * 32 + x) * 4;

                        if(idx == 0) {
                            pixels[offset + 3] = 0; // transparent
                        } else {
                            uint16_t color = palette[idx];
                            uint8_t r = ((color >> 10) & 0x1F);
                            uint8_t g = ((color >> 5) & 0x1F);
                            uint8_t b = (color & 0x1F);
                            pixels[offset + 0] = (r << 3) | (r >> 2);
                            pixels[offset + 1] = (g << 3) | (g >> 2);
                            pixels[offset + 2] = (b << 3) | (b >> 2);
                            pixels[offset + 3] = 0xFF;
                        }
                    }
                }
            }
        }
    }

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:32 pixelsHigh:32
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:32*4 bitsPerPixel:32];
    memcpy([rep bitmapData], pixels, sizeof(pixels));

    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(32, 32)];
    [image addRepresentation:rep];
    return image;
}

#pragma mark - Save State Screenshot Lookup

static NSImage *OE_screenshotForROMAtURL(NSURL *romURL)
{
    NSString *md5 = OE_md5ForFileAtURL(romURL);
    if(!md5) return nil;

    NSString *statesDir = [[@"~/Library/Application Support/OpenEmu/Save States"
                            stringByExpandingTildeInPath]
                           stringByAppendingPathComponent:md5];

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir;
    if(![fm fileExistsAtPath:statesDir isDirectory:&isDir] || !isDir)
        return nil;

    NSArray *contents = [fm contentsOfDirectoryAtPath:statesDir error:nil];
    for(NSString *item in contents) {
        if(![[item pathExtension] isEqualToString:@"oesavestate"])
            continue;

        NSString *screenshotPath = [[statesDir stringByAppendingPathComponent:item]
                                    stringByAppendingPathComponent:@"ScreenShot"];
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:screenshotPath];
        if(image) return image;
    }

    return nil;
}

#pragma mark - Console Image Lookup

static NSImage *OE_consoleImageForExtension(NSString *ext)
{
    // Map file extensions to system plugin names
    NSDictionary *extToSystem = @{
        @"smc": @"SuperNES", @"sfc": @"SuperNES",
        @"nes": @"NES",
        @"gb": @"GameBoy", @"gbc": @"GameBoy", @"sgb": @"GameBoy",
        @"gba": @"GameBoy Advance",
        @"smd": @"Genesis", @"md": @"Genesis", @"gen": @"Genesis",
        @"nds": @"NDS",
    };

    NSString *systemName = [extToSystem objectForKey:[ext lowercaseString]];
    if(!systemName) return nil;

    // Find the app bundle by looking for OpenEmu.app in common locations
    NSArray *searchPaths = @[
        @"/Applications/OpenEmu.app",
        [@"~/Applications/OpenEmu.app" stringByExpandingTildeInPath],
        [@"~/Desktop/OpenEmu.app" stringByExpandingTildeInPath],
    ];

    // Also check running app via Launch Services
    NSString *appPath = [[NSWorkspace sharedWorkspace] absolutePathForAppBundleWithIdentifier:@"org.openemu.OpenEmu"];
    if(appPath) searchPaths = [@[appPath] arrayByAddingObjectsFromArray:searchPaths];

    NSFileManager *fm = [NSFileManager defaultManager];
    for(NSString *path in searchPaths) {
        NSString *pluginPath = [NSString stringWithFormat:@"%@/Contents/PlugIns/Systems/%@.oesystemplugin/Contents/Resources",
                                path, systemName];

        NSArray *contents = [fm contentsOfDirectoryAtPath:pluginPath error:nil];
        for(NSString *file in contents) {
            if([file rangeOfString:@"_library"].location != NSNotFound) {
                NSImage *img = [[NSImage alloc] initWithContentsOfFile:[pluginPath stringByAppendingPathComponent:file]];
                if(img) return img;
            }
        }
    }

    return nil;
}

#pragma mark - Drawing

static void OE_drawThumbnailWithScreenshot(NSImage *screenshot, NSImage *consoleImage, CGContextRef cgContext, CGSize size)
{
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithGraphicsPort:cgContext flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:gc];

    // All measurements relative to 256x256 canvas from the SVG
    CGFloat s = size.width / 256.0;

    NSRect outerRect = NSMakeRect(4*s, 4*s, 248*s, 248*s);
    CGFloat outerRadius = 52*s;

    NSRect innerRect = NSMakeRect(14*s, 14*s, 228*s, 228*s);
    CGFloat innerRadius = 43*s;

    NSBezierPath *outerPath = [NSBezierPath bezierPathWithRoundedRect:outerRect xRadius:outerRadius yRadius:outerRadius];
    NSBezierPath *innerPath = [NSBezierPath bezierPathWithRoundedRect:innerRect xRadius:innerRadius yRadius:innerRadius];

    // Drop shadow
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [[NSShadow alloc] init];
    [shadow setShadowOffset:NSMakeSize(0, -2*s)];
    [shadow setShadowBlurRadius:4*s];
    [shadow setShadowColor:[NSColor colorWithCalibratedWhite:0.0 alpha:0.15]];
    [shadow set];
    [[NSColor blackColor] setFill];
    [outerPath fill];
    [NSGraphicsContext restoreGraphicsState];

    // Black screen background
    [[NSColor blackColor] setFill];
    [innerPath fill];

    if(screenshot) {
        // Draw screenshot cropped to fill
        NSSize imgSize = [screenshot size];
        CGFloat screenAspect = innerRect.size.width / innerRect.size.height;
        CGFloat imgAspect = imgSize.width / imgSize.height;
        NSRect srcRect;
        if(imgAspect > screenAspect) {
            CGFloat cropWidth = imgSize.height * screenAspect;
            srcRect = NSMakeRect((imgSize.width - cropWidth) / 2.0, 0, cropWidth, imgSize.height);
        } else {
            CGFloat cropHeight = imgSize.width / screenAspect;
            srcRect = NSMakeRect(0, (imgSize.height - cropHeight) / 2.0, imgSize.width, cropHeight);
        }

        [NSGraphicsContext saveGraphicsState];
        [innerPath setClip];
        [screenshot drawInRect:innerRect fromRect:srcRect operation:NSCompositeSourceOver fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];
    } else if(consoleImage) {
        // Draw console image at native pixel size, or 2x if it fits cleanly
        NSBitmapImageRep *centerRep = nil;
        for(NSImageRep *r in [consoleImage representations]) {
            if([r isKindOfClass:[NSBitmapImageRep class]]) { centerRep = (NSBitmapImageRep *)r; break; }
        }
        NSSize imgSize = centerRep ? NSMakeSize([centerRep pixelsWide], [centerRep pixelsHigh]) : [consoleImage size];
        CGFloat maxW = innerRect.size.width * 0.85;
        CGFloat maxH = innerRect.size.height * 0.85;
        CGFloat scale = 1.0;
        if(imgSize.width * 2.0 <= maxW && imgSize.height * 2.0 <= maxH)
            scale = 2.0;
        else if(imgSize.width > maxW || imgSize.height > maxH)
            scale = fmin(maxW / imgSize.width, maxH / imgSize.height);

        NSSize drawSize = NSMakeSize(imgSize.width * scale, imgSize.height * scale);
        NSRect drawRect = NSMakeRect(NSMidX(innerRect) - drawSize.width / 2.0,
                                     NSMidY(innerRect) - drawSize.height / 2.0,
                                     drawSize.width, drawSize.height);

        [NSGraphicsContext saveGraphicsState];
        [innerPath setClip];
        [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationNone];
        [consoleImage drawInRect:drawRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];
    }

    // Red frame: fill outer path, then punch out inner path
    // Use even-odd rule to create the frame shape
    NSBezierPath *framePath = [outerPath copy];
    [framePath appendBezierPath:innerPath];
    [framePath setWindingRule:NSEvenOddWindingRule];

    // Red gradient (SVG: #a52020 -> #8b1515 -> #6e0e0e)
    [NSGraphicsContext saveGraphicsState];
    [framePath setClip];
    NSGradient *frameGrad = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithCalibratedRed:0.647 green:0.125 blue:0.125 alpha:1.0],
        [NSColor colorWithCalibratedRed:0.545 green:0.082 blue:0.082 alpha:1.0],
        [NSColor colorWithCalibratedRed:0.431 green:0.055 blue:0.055 alpha:1.0],
    ] atLocations:(const CGFloat[]){0.0, 0.45, 1.0} colorSpace:[NSColorSpace genericRGBColorSpace]];
    [frameGrad drawInRect:outerRect angle:270];

    // Bottom shadow on frame (SVG: shadowGrad from y=168)
    NSGradient *bottomShadow = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.0 alpha:0.0]
                                                            endingColor:[NSColor colorWithCalibratedWhite:0.0 alpha:0.22]];
    [bottomShadow drawInRect:NSMakeRect(outerRect.origin.x, outerRect.origin.y, outerRect.size.width, outerRect.size.height * 0.33) angle:270];
    [NSGraphicsContext restoreGraphicsState];

    // Outer edge highlight stroke
    [[NSColor colorWithCalibratedRed:0.769 green:0.188 blue:0.188 alpha:0.35] setStroke];
    [outerPath setLineWidth:0.75*s];
    [outerPath stroke];

    // Inner inset shadow stroke
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.25] setStroke];
    [innerPath setLineWidth:1.2*s];
    [innerPath stroke];

    // CRT gloss highlight over everything
    [NSGraphicsContext saveGraphicsState];
    [outerPath setClip];
    NSBezierPath *glossPath = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-22*s, (256-155)*s, 300*s, 290*s)];
    NSGradient *glossGrad = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithCalibratedWhite:1.0 alpha:1.0],
        [NSColor colorWithCalibratedWhite:1.0 alpha:0.6],
        [NSColor colorWithCalibratedWhite:1.0 alpha:0.15],
        [NSColor colorWithCalibratedWhite:1.0 alpha:0.0],
    ] atLocations:(const CGFloat[]){0.0, 0.35, 0.65, 1.0} colorSpace:[NSColorSpace genericRGBColorSpace]];
    [glossGrad drawInBezierPath:glossPath angle:270];
    [NSGraphicsContext restoreGraphicsState];

    [NSGraphicsContext restoreGraphicsState];
}

#pragma mark - QuickLook Entry Points

OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize)
{
    @autoreleasepool {
        NSURL *romURL = (__bridge NSURL *)url;
        NSString *ext = [[romURL pathExtension] lowercaseString];

        // For NDS ROMs, always use the game's embedded icon instead of a screenshot
        NSImage *screenshot = nil;
        NSImage *consoleImage = nil;
        if([ext isEqualToString:@"nds"]) {
            consoleImage = OE_iconFromNDSROM(romURL);
        } else {
            screenshot = OE_screenshotForROMAtURL(romURL);
            if(!screenshot)
                consoleImage = OE_consoleImageForExtension(ext);
        }

        // If we have neither a screenshot nor a console image, let Finder use default icon
        if(!screenshot && !consoleImage) return noErr;

        CGFloat dim = fmin(maxSize.width, maxSize.height);
        CGSize size = CGSizeMake(dim, dim);

        NSDictionary *properties = @{
            (NSString *)kQLThumbnailPropertyExtensionKey: @"",
            @"IconFlavor": @0,
        };
        CGContextRef cgContext = QLThumbnailRequestCreateContext(thumbnail, size, true, (__bridge CFDictionaryRef)properties);
        if(cgContext) {
            OE_drawThumbnailWithScreenshot(screenshot, consoleImage, cgContext, size);
            QLThumbnailRequestFlushContext(thumbnail, cgContext);
            CFRelease(cgContext);
        }
    }
    return noErr;
}

void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail)
{}

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options)
{
    @autoreleasepool {
        NSURL *romURL = (__bridge NSURL *)url;
        NSImage *screenshot = OE_screenshotForROMAtURL(romURL);
        if(!screenshot) return noErr;

        NSSize imgSize = [screenshot size];
        CGSize size = CGSizeMake(imgSize.width, imgSize.height);

        CGContextRef cgContext = QLPreviewRequestCreateContext(preview, size, true, NULL);
        if(cgContext) {
            NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithGraphicsPort:cgContext flipped:NO];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:gc];
            [screenshot drawAtPoint:NSZeroPoint fromRect:NSZeroRect operation:NSCompositeCopy fraction:1.0];
            [NSGraphicsContext restoreGraphicsState];
            QLPreviewRequestFlushContext(preview, cgContext);
            CFRelease(cgContext);
        }
    }
    return noErr;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview)
{}
