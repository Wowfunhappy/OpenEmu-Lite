/*
 Copyright (c) 2013, OpenEmu Team

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

#import "OECheats.h"

// NSUserDefaults key mapping md5 hash -> array of cheat dictionaries.
static NSString *const OECheatsDefaultsKey = @"OECheats";

@implementation OECheats

+ (NSMutableArray *)cheatsForMD5:(NSString *)md5
{
    NSMutableArray *cheats = [NSMutableArray array];
    if(md5 == nil) return cheats;

    NSDictionary *store = [[NSUserDefaults standardUserDefaults] dictionaryForKey:OECheatsDefaultsKey];
    NSArray *stored = [store objectForKey:md5];

    // Rehydrate as mutable dictionaries so callers can flip "enabled" in place.
    for(NSDictionary *cheat in stored)
        [cheats addObject:[cheat mutableCopy]];

    return cheats;
}

+ (void)setCheats:(NSArray *)cheats forMD5:(NSString *)md5
{
    if(md5 == nil) return;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *store = [[defaults dictionaryForKey:OECheatsDefaultsKey] mutableCopy] ?: [NSMutableDictionary dictionary];

    if([cheats count] == 0)
    {
        [store removeObjectForKey:md5];
    }
    else
    {
        // Store immutable, property-list-safe copies.
        NSMutableArray *plistCheats = [NSMutableArray arrayWithCapacity:[cheats count]];
        for(NSDictionary *cheat in cheats)
            [plistCheats addObject:[cheat copy]];
        [store setObject:plistCheats forKey:md5];
    }

    [defaults setObject:store forKey:OECheatsDefaultsKey];
    [defaults synchronize];
}

@end
