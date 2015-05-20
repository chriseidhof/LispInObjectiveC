//
//  Lisp.h
//  LispInObjectiveC
//
//  Created by Chris Eidhof on 11/22/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface Env : NSObject
@property (nonatomic,retain) Env* outer;
@property (nonatomic,retain) NSMutableDictionary* items;
- (Env*)find:(NSString*)var;
@end

@interface Lisp : NSObject

- (void)test;

@end