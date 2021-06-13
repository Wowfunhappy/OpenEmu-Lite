/*
 Copyright (c) 2012, OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 *Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 *Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 *Neither the name of the OpenEmu Team nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEPopoutGameWindowController.h"

#import "OEHUDWindow.h"
#import "OEGameDocument.h"
#import "OEGameViewController.h"
#import "OEGameView.h"
#import "NSViewController+OEAdditions.h"
#import "NSWindow+OEFullScreenAdditions.h"
#import <QuartzCore/QuartzCore.h>
#import "OEUtilities.h"

#import "OEDBRom.h"
#import "OEDBGame.h"
#import "OEDBSystem.h"

#pragma mark - Private variables

static const NSSize       _OEPopoutGameWindowMinSize = {100, 100};
static const NSSize       _OEScreenshotWindowMinSize = {100, 100};
static const unsigned int _OEFitToWindowScale        = 0;

// User defaults
static NSString *const _OESystemIntegralScaleKeyFormat = @"OEIntegralScale.%@";
static NSString *const _OEIntegralScaleKey             = @"integralScale";
static NSString *const _OELastWindowSizeKey            = @"lastPopoutWindowSize";

typedef enum
{
    _OEPopoutGameWindowFullScreenStatusNonFullScreen = 0,
    _OEPopoutGameWindowFullScreenStatusFullScreen,
    _OEPopoutGameWindowFullScreenStatusEntering,
    _OEPopoutGameWindowFullScreenStatusExiting,
} OEPopoutGameWindowFullScreenStatus;



@interface OEScreenshotWindow : NSWindow
@property(nonatomic, unsafe_unretained) NSImageView *screenshotView;
@property(nonatomic, unsafe_unretained) NSImage     *screenshot;
@end



@implementation OEPopoutGameWindowController
{
    NSScreen                           *_screenBeforeWindowMove;
    unsigned int                        _integralScale;

    // Full screen
    NSRect                              _frameForNonFullScreenMode;
    OEScreenshotWindow                 *_screenshotWindow;
    OEPopoutGameWindowFullScreenStatus  _fullScreenStatus;
    BOOL                                _resumePlayingAfterFullScreenTransition;
}

#pragma mark - NSWindowController overridden methods

- (id)initWithWindow:(NSWindow *)window
{
    self = [super initWithWindow:window];
    if(!self)
        return nil;

    [window setDelegate:self];
    [window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
    [window setAnimationBehavior:NSWindowAnimationBehaviorDocumentWindow];
    [window setMinSize:_OEPopoutGameWindowMinSize];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(OE_constrainIntegralScaleIfNeeded) name:NSApplicationDidChangeScreenParametersNotification object:nil];

    return self;
}

- (void)dealloc
{
    [[self window] setDelegate:nil];
    [self setWindow:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)windowShouldClose:(id)sender
{
    return [self document] != nil;
}

- (void)setDocument:(NSDocument *)document
{
    NSAssert(!document || [document isKindOfClass:[OEGameDocument class]], @"OEPopoutGameWindowController accepts OEGameDocument documents only");

    [super setDocument:document];

    if(document != nil)
    {
        OEGameViewController *gameViewController = [[self OE_gameDocument] gameViewController];
        NSString *systemIdentifier               = [[[[[gameViewController document] rom] game] system] systemIdentifier];
        NSUserDefaults *defaults                 = [NSUserDefaults standardUserDefaults];
        unsigned int maxScale                    = [self maximumIntegralScale];
        NSDictionary *integralScaleInfo          = [defaults objectForKey:[NSString stringWithFormat:_OESystemIntegralScaleKeyFormat, systemIdentifier]];
        NSNumber *lastScaleNumber                = [integralScaleInfo objectForKey:_OEIntegralScaleKey];
        NSSize windowSize;

        _integralScale = ([lastScaleNumber respondsToSelector:@selector(unsignedIntValue)] ?
                          MIN([lastScaleNumber unsignedIntValue], maxScale) :
                          maxScale);

        if(_integralScale == _OEFitToWindowScale)
        {
            windowSize = NSSizeFromString([integralScaleInfo objectForKey:_OELastWindowSizeKey]);
            if(windowSize.width == 0 || windowSize.height == 0)
                windowSize = [self OE_windowSizeForGameViewIntegralScale:maxScale];
        }
        else
            windowSize = [self OE_windowSizeForGameViewIntegralScale:_integralScale];

        OEHUDWindow *window     = (OEHUDWindow *)[self window];
        const NSRect windowRect = {NSZeroPoint, windowSize};

        [gameViewController setIntegralScalingDelegate:self];

        [window setFrame:windowRect display:NO animate:NO];
        [window center];
        [window setContentAspectRatio:[gameViewController defaultScreenSize]];
        [[window contentView] addSubview:[gameViewController view]];
        const NSRect contentRect = [[window contentView]frame];
        [[gameViewController view] setFrame:contentRect];
        [[gameViewController view] setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

        [self OE_buildScreenshotWindow];
    }
}

- (void)showWindow:(id)sender
{
    NSWindow *window = [self window];

    if(![window isVisible])
    {
        OEGameViewController *gameViewController = [[self OE_gameDocument] gameViewController];
        
        [window makeKeyAndOrderFront:sender];

        [gameViewController viewWillAppear];
        [gameViewController viewDidAppear];
    }
}

#pragma mark - Actions

- (IBAction)changeIntegralScale:(id)sender;
{
    if(![sender respondsToSelector:@selector(representedObject)])
        return;
    if(![[sender representedObject] respondsToSelector:@selector(unsignedIntValue)])
        return;

    const unsigned int newScale = [[sender representedObject] unsignedIntValue];
    if(newScale > [self maximumIntegralScale])
        return;

    [self OE_changeGameViewIntegralScale:newScale];
}

#pragma mark - OEGameIntegralScalingDelegate

- (unsigned int)maximumIntegralScale
{
    NSScreen *screen            = ([[self window] screen] ? : [NSScreen mainScreen]);
    const NSSize maxContentSize = [OEHUDWindow mainContentRectForFrameRect:[screen visibleFrame]].size;
    const NSSize defaultSize    = [[[self OE_gameDocument] gameViewController] defaultScreenSize];
    const unsigned int maxScale = MAX(MIN(floor(maxContentSize.height / defaultSize.height), floor(maxContentSize.width / defaultSize.width)), 1);

    return maxScale;
}

- (unsigned int)currentIntegralScale
{
    return [[self window] isFullScreen] ? _OEFitToWindowScale : _integralScale;
}

- (BOOL)shouldAllowIntegralScaling
{
    return ![[self window] isFullScreen];
}

#pragma mark - Private methods

- (NSSize)OE_windowContentSizeForGameViewIntegralScale:(unsigned int)gameViewIntegralScale
{
    const NSSize defaultSize = [[[self OE_gameDocument] gameViewController] defaultScreenSize];
    const NSSize contentSize = OEScaleSize(defaultSize, (CGFloat)gameViewIntegralScale);

    return contentSize;
}

- (NSSize)OE_windowSizeForGameViewIntegralScale:(unsigned int)gameViewIntegralScale
{
    const NSSize contentSize = [self OE_windowContentSizeForGameViewIntegralScale:gameViewIntegralScale];
    const NSSize windowSize  = [OEHUDWindow frameRectForMainContentRect:(NSRect){.size = contentSize}].size;

    //Wowfunhappy: For some reason, windowSize is one pixel too high by default, screwing up integer scaling.
    //Meticulously confirmed by looking at striped patterns NESTopia and SNES 9X cores.
    return NSMakeSize(windowSize.width, windowSize.height - 1);
}

- (void)OE_changeGameViewIntegralScale:(unsigned int)newScale
{
    if(_fullScreenStatus != _OEPopoutGameWindowFullScreenStatusNonFullScreen)
        return;
    
    _integralScale = newScale;

    if(newScale != _OEFitToWindowScale)
    {
        const NSRect screenFrame = [[[self window] screen] visibleFrame];
        NSRect currentWindowFrame = [[self window] frame];
        NSRect newWindowFrame = { .size = [self OE_windowSizeForGameViewIntegralScale:newScale] };
        
        newWindowFrame.origin.y = roundf(NSMidY(currentWindowFrame)-newWindowFrame.size.height/2);
        newWindowFrame.origin.x = roundf(NSMidX(currentWindowFrame)-newWindowFrame.size.width/2);
        
        // Make sure the entire window is visible, centering it in case it isn’t
        if(NSMinY(newWindowFrame) < NSMinY(screenFrame) || NSMaxY(newWindowFrame) > NSMaxY(screenFrame))
            newWindowFrame.origin.y = NSMinY(screenFrame) + ((screenFrame.size.height - newWindowFrame.size.height) / 2);

        if(NSMinX(newWindowFrame) < NSMinX(screenFrame) || NSMaxX(newWindowFrame) > NSMaxX(screenFrame))
            newWindowFrame.origin.x = NSMinX(screenFrame) + ((screenFrame.size.width - newWindowFrame.size.width) / 2);

        [[[self window] animator] setFrame:newWindowFrame display:YES];
    }
}

- (void)OE_constrainIntegralScaleIfNeeded
{
    if(_fullScreenStatus != _OEPopoutGameWindowFullScreenStatusNonFullScreen || _integralScale == _OEFitToWindowScale)
        return;

    const unsigned int newMaxScale = [self maximumIntegralScale];
    const NSRect newScreenFrame    = [[[self window] screen] visibleFrame];
    const NSRect currentFrame      = [[self window] frame];

    if(newScreenFrame.size.width < currentFrame.size.width || newScreenFrame.size.height < currentFrame.size.height)
        [self OE_changeGameViewIntegralScale:newMaxScale];
}


//Wowfunhappy
//Disabled because it doesn't work properly - Stays checked on manual window resize.
/*
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    SEL action = [menuItem action];
    
    if(action == @selector(changeIntegralScale:))
    {
        NSLog(@"Wowfunhappy Testing: %d", [self currentIntegralScale]);
        NSLog(@"Wowfunhappy Testing: %d", [[menuItem title] substringFromIndex:1].intValue);
        if ([[menuItem representedObject] unsignedIntValue] == [self currentIntegralScale]) {
            [menuItem setState:NSOnState];
        } else {
            [menuItem setState:NSOffState];
        }
    }
    
    return YES;
}
 */



- (OEGameDocument *)OE_gameDocument
{
    return (OEGameDocument *)[self document];
}

- (void)OE_buildScreenshotWindow
{
    NSRect windowFrame = {.size = _OEScreenshotWindowMinSize};
    NSScreen *mainScreen                     = [[NSScreen screens] objectAtIndex:0];
    const NSRect screenFrame                 = [mainScreen frame];
    _screenshotWindow  = [[OEScreenshotWindow alloc] initWithContentRect:screenFrame
                                                               styleMask:NSBorderlessWindowMask
                                                                 backing:NSBackingStoreBuffered
                                                                   defer:NO];
    [_screenshotWindow setBackgroundColor:[NSColor clearColor]];
    [_screenshotWindow setOpaque:NO];
    [_screenshotWindow setAnimationBehavior:NSWindowAnimationBehaviorNone];

    
    const NSRect  contentFrame = {NSZeroPoint, windowFrame.size};
    NSImageView  *imageView    = [[NSImageView alloc] initWithFrame:contentFrame];
    [[imageView cell] setImageAlignment:NSImageAlignBottomLeft];
    [[imageView cell] setImageScaling:NSImageScaleAxesIndependently];
    [imageView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [imageView setWantsLayer:YES];
    [imageView setLayerContentsRedrawPolicy:NSViewLayerContentsRedrawOnSetNeedsDisplay];
    [imageView.layer setOpaque:YES];
    _screenshotWindow.screenshotView = imageView;

    [_screenshotWindow setContentView:imageView];
}

- (NSRect)OE_screenshotWindowFrameForOriginalFrame:(NSRect)frame
{
    OEGameViewController *gameViewController    = [[self OE_gameDocument] gameViewController];
    const NSSize          gameSize              = [gameViewController defaultScreenSize];
    const float           widthRatio            = gameSize.width  / frame.size.width;
    const float           heightRatio           = gameSize.height / frame.size.height;
    const float           dominantRatioInverse  = 1 / MAX(widthRatio, heightRatio);
    const NSSize          gameViewportSize      = OEScaleSize(gameSize, dominantRatioInverse);
    const NSPoint         gameViewportOrigin    =
    {
        NSMinX(frame) + ((frame.size.width  - gameViewportSize.width ) / 2),
        NSMinY(frame) + ((frame.size.height - gameViewportSize.height) / 2),
    };
    const NSRect          screenshotWindowFrame = {gameViewportOrigin, gameViewportSize};
    
    return screenshotWindowFrame;
}

- (void)OE_hideScreenshotWindow
{
    [_screenshotWindow orderOut:self];

    // Reduce the memory footprint of the screenshot window when it’s not visible
    [_screenshotWindow setScreenshot:nil];
    [_screenshotWindow.screenshotView.layer setFrame:(NSRect){.size = _OEScreenshotWindowMinSize}];
}

- (void)OE_forceLayerReposition:(CALayer *)layer toFrame:(NSRect)frame
{
    // This forces the CALayer to reposition
    // without this we see the previous state for a split second
    CABasicAnimation *moveToPosition = [CABasicAnimation animationWithKeyPath:@"position"];
    moveToPosition.fromValue = [NSValue valueWithPoint:frame.origin];
    moveToPosition.toValue = [NSValue valueWithPoint:frame.origin];
    moveToPosition.duration = 0;
    moveToPosition.fillMode = kCAFillModeForwards;
    moveToPosition.removedOnCompletion = NO;

    CABasicAnimation *scaleToSize = [CABasicAnimation animationWithKeyPath:@"bounds.size"];
    scaleToSize.fromValue = [NSValue valueWithSize:frame.size];
    scaleToSize.toValue = [NSValue valueWithSize:frame.size];
    scaleToSize.duration = 0;
    scaleToSize.fillMode = kCAFillModeForwards;
    scaleToSize.removedOnCompletion = NO;

    [_screenshotWindow.screenshotView.layer addAnimation:moveToPosition forKey:@"moveToPosition"];
    [_screenshotWindow.screenshotView.layer addAnimation:scaleToSize forKey:@"scaleToSize"];
}

#pragma mark - NSWindowDelegate

- (void)windowWillMove:(NSNotification *)notification
{
    if(_fullScreenStatus != _OEPopoutGameWindowFullScreenStatusNonFullScreen)
        return;

    _screenBeforeWindowMove = [[self window] screen];
}

- (void)windowDidMove:(NSNotification *)notification
{
    if(_fullScreenStatus != _OEPopoutGameWindowFullScreenStatusNonFullScreen)
        return;

    if(_screenBeforeWindowMove != [[self window] screen])
        [self OE_constrainIntegralScaleIfNeeded];

    _screenBeforeWindowMove = nil;
}

- (void)windowDidChangeScreen:(NSNotification *)notification
{
    if(_fullScreenStatus != _OEPopoutGameWindowFullScreenStatusNonFullScreen)
        return;

    [self OE_constrainIntegralScaleIfNeeded];
}

- (void)windowWillClose:(NSNotification *)notification
{
    OEGameViewController *gameViewController = [[self OE_gameDocument] gameViewController];

    const NSSize windowSize         = ([[self window] isFullScreen] ? _frameForNonFullScreenMode.size : [[self window] frame].size);
    NSString *systemIdentifier      = [[[[[gameViewController document] rom] game] system] systemIdentifier];
    NSUserDefaults *userDefaults    = [NSUserDefaults standardUserDefaults];
    NSString *systemKey             = [NSString stringWithFormat:_OESystemIntegralScaleKeyFormat, systemIdentifier];
    NSDictionary *integralScaleInfo = @{
        _OEIntegralScaleKey  : @(_integralScale),
        _OELastWindowSizeKey : NSStringFromSize(windowSize),
    };
    [userDefaults setObject:integralScaleInfo forKey:systemKey];
    [userDefaults synchronize]; // needed whilst AppKit isn’t fixed to synchronise defaults in -_deallocHardCore:

    [gameViewController viewWillDisappear];
    [gameViewController viewDidDisappear];
}


 //Wowfunhappy: We can't use this, allows windows to be sized to overlap the Dock.
/*- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize
{
    _integralScale = _OEFitToWindowScale;
    const NSSize windowSize  = [OEHUDWindow frameRectForMainContentRect:(NSRect){.size = frameSize}].size;

    NSLog(@"Wowfunhappy, windowWillResize: %@", windowSize);
    return windowSize;
}*/



- (void)cancelOperation:(id)sender
{
    if([[self window] isFullScreen])
        [[self window] toggleFullScreen:self];
}

#pragma mark - NSWindowDelegate Full Screen



- (void)windowWillEnterFullScreen:(NSNotification *)notification
{
    NSRect mainDisplayRect = [[NSScreen mainScreen] frame];
    [[self window] setContentAspectRatio:NSMakeSize(mainDisplayRect.size.width, mainDisplayRect.size.height)];
}
- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
    _fullScreenStatus = _OEPopoutGameWindowFullScreenStatusFullScreen;
}

- (void)windowWillExitFullScreen:(NSNotification *)notification
{
    OEGameViewController *gameViewController = [[self OE_gameDocument] gameViewController];
    [[self window] setContentAspectRatio:[gameViewController defaultScreenSize]];
}
- (void)windowDidExitFullScreen:(NSNotification *)notification
{
    _fullScreenStatus = _OEPopoutGameWindowFullScreenStatusNonFullScreen;
}

@end

@implementation OEScreenshotWindow

- (void)setScreenshot:(NSImage *)screenshot
{
    [[self screenshotView] setImage:screenshot];
}

@end
