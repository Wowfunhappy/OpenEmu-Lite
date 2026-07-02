/*
 Copyright (c) 2024, OpenEmu Team

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

#import "OEPICO8SystemResponder.h"
#import "OEPICO8SystemResponderClient.h"

@implementation OEPICO8SystemResponder
@dynamic client;

+ (Protocol *)gameSystemResponderClientProtocol;
{
    return @protocol(OEPICO8SystemResponderClient);
}

- (void)pressEmulatorKey:(OESystemKey *)aKey
{
    if ([aKey key] == OEPICO8ButtonPause) {
        // Route through the emulation pause toggle so the menu item stays in sync
        [[self globalEventsHandler] toggleEmulationPaused:self];
        return;
    }
    [[self client] didPushPICO8Button:(OEPICO8Button)[aKey key]];
}

- (void)releaseEmulatorKey:(OESystemKey *)aKey
{
    if ([aKey key] == OEPICO8ButtonPause)
        return;
    [[self client] didReleasePICO8Button:(OEPICO8Button)[aKey key]];
}

// The base class only routes left-button events; PICO-8's devkit mouse
// (stat 34) also reports the right button, so handle the full set here.
- (void)handleMouseEvent:(OEEvent *)event
{
    OEIntPoint point = [event locationInGameView];
    switch([event type])
    {
        case NSLeftMouseDown :
        case NSLeftMouseDragged :
            [[self client] leftMouseDownAtPoint:point];
            break;
        case NSLeftMouseUp :
            [[self client] leftMouseUp];
            break;
        case NSRightMouseDown :
        case NSRightMouseDragged :
            [[self client] rightMouseDownAtPoint:point];
            break;
        case NSRightMouseUp :
            [[self client] rightMouseUp];
            break;
        case NSMouseMoved :
            [[self client] mouseMovedAtPoint:point];
            break;
        default :
            break;
    }
}

// Forward raw key events for the devkit keyboard (stat 30/31) in addition
// to the normal bindings (super), which keep btn()/btnp() working.
- (void)HIDKeyDown:(OEHIDEvent *)anEvent
{
    [[self client] didPressKey:[anEvent keycode]];
    [super HIDKeyDown:anEvent];
}

- (void)HIDKeyUp:(OEHIDEvent *)anEvent
{
    [[self client] didReleaseKey:[anEvent keycode]];
    [super HIDKeyUp:anEvent];
}

@end
