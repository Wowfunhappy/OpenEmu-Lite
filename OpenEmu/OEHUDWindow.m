/*
 Copyright (c) 2011, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * Neither the name of the OpenEmu Team nor the
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

#import "OEHUDWindow.h"
#import "NSImage+OEDrawingAdditions.h"
#import "NSColor+OEAdditions.h"

#import "OEButton.h"
#import "OEButtonCell.h"
#import "OETheme.h"
#pragma mark - Private variables

static const CGFloat _OEHUDWindowLeftBorder            =  1.0;
static const CGFloat _OEHUDWindowRightBorder           =  1.0;
static const CGFloat _OEHUDWindowBottomBorder          =  1.0;
static const CGFloat _OEHUDWindowTopBorder             = 22.0;

@interface OEHUDWindow () <NSWindowDelegate>

- (void)OE_commonHUDWindowInit;

@end

@implementation OEHUDWindow
{
    NSBox                    *_backgroundView;
    BOOL                      _isDeallocating;
}

#pragma mark - Lifecycle

- (id)initWithContentRect:(NSRect)frame
{
    return [self initWithContentRect:frame styleMask:NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
}

- (void)dealloc 
{
    _isDeallocating = YES;
    _borderWindow = nil;
    [super setDelegate:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)anItem
{
    if([super validateUserInterfaceItem:anItem])
        return YES;

    return [anItem action] == @selector(performClose:);
}

- (void)performClose:(id)sender
{
    NSWindowController *windowController = [self windowController];
    NSDocument *document = [windowController document];

    if(document != nil && windowController != nil)
        [document shouldCloseWindowController:windowController delegate:self shouldCloseSelector:@selector(_document:shouldClose:contextInfo:) contextInfo:NULL];
    else
        [self _document:nil shouldClose:YES contextInfo:NULL];
}

- (void)_document:(NSDocument *)document shouldClose:(BOOL)shouldClose contextInfo:(void  *)contextInfo
{
    if(shouldClose)
    {
        if([[self delegate] respondsToSelector:@selector(windowShouldClose:)])
            shouldClose = [[self delegate] windowShouldClose:self];
        else if([self respondsToSelector:@selector(windowShouldClose:)])
            shouldClose = [self windowShouldClose:self];
    }

    if(shouldClose) [self close];
}

#pragma mark - NSWindow overrides


#pragma mark - Public

- (NSColor *)contentBackgroundColor
{
    return [_backgroundView fillColor];
}

- (void)setContentBackgroundColor:(NSColor *)value
{
    [_backgroundView setFillColor:value];
}

- (void)setMainContentView:(NSView *)value
{
    if(_mainContentView == value)
        return;

    //[_mainContentView removeFromSuperview];
    _mainContentView = value;

    [[super contentView] addSubview:_mainContentView];

    const NSRect contentRect = [self convertRectFromScreen:[OEHUDWindow mainContentRectForFrameRect:[self frame]]];
    [_mainContentView setFrame:contentRect];
    [_mainContentView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
}

+ (NSRect)mainContentRectForFrameRect:(NSRect)windowFrame
{
    NSRect contentRect = windowFrame;

    contentRect.origin.x    += _OEHUDWindowLeftBorder;
    contentRect.origin.y    += _OEHUDWindowBottomBorder;
    contentRect.size.width  -= (_OEHUDWindowLeftBorder + _OEHUDWindowRightBorder);
    contentRect.size.height -= (_OEHUDWindowTopBorder  + _OEHUDWindowBottomBorder);

    return contentRect;
}

+ (NSRect)frameRectForMainContentRect:(NSRect)contentFrame
{
    NSRect windowFrame = contentFrame;

    windowFrame.origin.x    -= _OEHUDWindowLeftBorder;
    windowFrame.origin.y    -= _OEHUDWindowBottomBorder;
    windowFrame.size.width  += (_OEHUDWindowLeftBorder + _OEHUDWindowRightBorder);
    windowFrame.size.height += (_OEHUDWindowTopBorder  + _OEHUDWindowBottomBorder);

    return windowFrame;
}

@end