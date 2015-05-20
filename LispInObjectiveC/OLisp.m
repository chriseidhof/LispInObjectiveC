//
//  OLisp.m
//  LispInObjectiveC
//
//  Created by Chris Eidhof on 11/24/11.
//  Copyright (c) 2011 __MyCompanyName__. All rights reserved.
//

#import "OLisp.h"
#import <objc/runtime.h>

@interface OClass : NSObject {
    Class theClass;
}
@end

@implementation OClass

- (id)initWithClass:(Class)clazz {
    self = [super init];
    if(self) {
        theClass = clazz;
    }
    return self;
}

- (NSString*)description {
    const char* name = class_getName(theClass);
    NSString* x = [[NSString alloc] initWithUTF8String:name];
    return [NSString stringWithFormat:@"<OClass: %@>", x];
}
@end

@interface OEnv : NSObject
@property (nonatomic,retain) OEnv* outer;
@property (nonatomic,retain) NSMutableDictionary* items;
- (OEnv*)find:(NSString*)var;
@end

@implementation OEnv

@synthesize outer, items;

- (id)initWithOuterEnv:(OEnv*)env {
    self = [super init];
    if(self) {
        self.outer = env;
        self.items = [NSMutableDictionary dictionary];
    }
    return self;
}

- (OEnv*)find:(NSString*)var {
    return [self.items objectForKey:var] ? self : [self.outer find:var];
}

- (void)setObject:(id)theObject forKey:(id)aKey {
    [self.items setObject:theObject forKey:aKey];
}

- (id)objectForKey:(id)aKey {
    id result = [self.items objectForKey:aKey];
    result = result ? result : [self.outer objectForKey:aKey];
    if(result == nil && [aKey isKindOfClass:[NSString class]]) {
        Class theClass = NSClassFromString(aKey);
        if(theClass != nil) {
            return [[OClass alloc] initWithClass:theClass];
        }
    }
    return result;
}

- (NSString*)description {
    return [NSString stringWithFormat:@"<env: %@, outer: %@>", self.items, self.outer];
}

@end

@implementation OLisp

// To parse a lisp expression, we first tokenize it. The result is an NSArray containing "(", ")" or atom tokens.

- (NSArray*)tokenize:(NSString*)input {
    NSArray* components = [[[input
                             stringByReplacingOccurrencesOfString:@"(" withString:@" ( "]
                            stringByReplacingOccurrencesOfString:@")" withString:@" ) "]
                           componentsSeparatedByString:@" "];
    return [components filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        return ![evaluatedObject isEqualToString:@""];
    }]];
}

// An atom is either a textual atom or a number, which is parsed as a double
- (NSObject*)atom:(NSString*)token {
    NSScanner* scanner = [NSScanner scannerWithString:token];
    double num = 0;
    return [scanner scanDouble:&num] ? [NSNumber numberWithDouble:num] : token;
}

// Converts a one-dimensional NSArray of tokens into an NSArray containing nested NSArrays and atoms
- (NSObject*)expression:(NSMutableArray*)tokens {
    if([tokens count] == 0) {
        @throw [NSException exceptionWithName:@"Syntax Error" reason:@"Unexpected EOF" userInfo:nil];
    }
    NSString* token = [tokens objectAtIndex:0];
    [tokens removeObjectAtIndex:0];
    if([token isEqualToString:@"("]) {
        NSMutableArray* l = [NSMutableArray array];
        while(![[tokens objectAtIndex:0] isEqualToString:@")"]) {
            [l addObject:[self expression:tokens]];
        }
        if([tokens count] == 0) {
            @throw [NSException exceptionWithName:@"Syntax Error" reason:@"Unexpected EOF" userInfo:nil];
        }
        [tokens removeObjectAtIndex:0]; // Remove the ')'
        return l;
    } else if([token isEqualToString:@")"]) {
        @throw [NSException exceptionWithName:@"Syntax Error" reason:@"Unexpected )" userInfo:nil];
    } else {
        return [self atom:token];
    }
}

// Evaluate an expression
- (id)eval:(NSObject*)x env:(OEnv*)env {
    // Symbols are looked up in the environment
    if([x isKindOfClass:[NSString class]]) {
        return [env objectForKey:x];
    }
    // Other values (i.e. numbers) are returned directly
    if(![x isKindOfClass:[NSArray class]]) { return x; }

    // Now we know x is of the form (a b c ...), i.e. a function call.
    // The first item in the list (scrutinee) is the function, the rest are arguments.
    NSArray* exp = (NSArray*)x; // x is an array
    NSString* scrutinee = [exp objectAtIndex:0];
    if([scrutinee isEqual:@"quote"]) {
        return [exp objectAtIndex:1];
    } else if([scrutinee isEqual:@"if"]) {
        NSArray* testResult     = (NSArray*)[self eval:[exp objectAtIndex:1] env:env];
        NSNumber* testResultNum = (NSNumber*)testResult;
        BOOL emptyArray = [testResult isKindOfClass:[NSArray class]] && [testResult count] == 0;
        BOOL zero       = [testResultNum isKindOfClass:[NSNumber class]] && [testResultNum intValue] == 0;
        return [self eval:[exp objectAtIndex:(emptyArray || zero ? 3 : 2)] env:env];
    } else if([scrutinee isEqual:@"lambda"]) {
        // Lambda's are represented by blocks
        id body = [exp objectAtIndex:2];
        NSArray* vars = [exp objectAtIndex:1];
        return [^(NSArray* args) {
            OEnv* newEnv = [[OEnv alloc] initWithOuterEnv:env];
            [vars enumerateObjectsUsingBlock:^(NSString* var, NSUInteger idx, BOOL* stop) {
                NSObject* arg = [args objectAtIndex:idx];
                NSAssert(arg != NULL, @"Should have an arg");
                [newEnv setObject:arg forKey:var];
            }];
            return [self eval:body env:newEnv];
        } copy];
//    } else if([scrutinee isEqual:@"set!"]) {
//        NSString* var = [exp objectAtIndex:1];
//        NSObject* result = [self eval:[exp objectAtIndex:2] env:env];
//        [[env find:var] setObject:result forKey:var];
//        return nil;
    } else if([scrutinee isEqual:@"begin"]) {
        NSArray* exprs = [exp subarrayWithRange:NSMakeRange(1, [exp count]-1)];
        NSObject* val = nil;
        for(NSObject* e in exprs) {
            val = [self eval:e env:env];
        }
        return val;
    } else if([scrutinee isEqual:@"define"]) {
        NSObject* result = [self eval:[exp objectAtIndex:2] env:env];
        NSAssert(result != NULL, @"Should have a result: %@", exp);
        [env setObject:result forKey:[exp objectAtIndex:1]];
    } else {
        NSObject* (^theBlock)(NSArray* args) = [self eval:scrutinee env:env];
        // To be sure, we check if theBlock is really an instance of the (undocumented) NSBlock class
        if([theBlock isKindOfClass:NSClassFromString(@"NSBlock")]) {
            NSMutableArray* blockArgs = [NSMutableArray array];
            for(NSObject* arg in [exp subarrayWithRange:NSMakeRange(1, [exp count]-1)]) {
                [blockArgs addObject:[self eval:arg env:env]];
            }
            return theBlock(blockArgs);
        } else {
            NSLog(@"couldn't interpret: %@, env: %@ - %@", x, env, theBlock);
        }

    }
    return nil;
}

- (OEnv*)builtins {
#define arg1 [args objectAtIndex:0]
#define arg2 [args objectAtIndex:1]
#define num(arg) [NSNumber numberWithDouble:arg]
#define binaryop(arg) return [NSNumber numberWithDouble:[arg1 doubleValue] arg [arg2 doubleValue]]
#define addBinaryOp(arg) [builtins setObject:^(NSArray* args) { binaryop(arg); } forKey:@"" #arg ""];
#define addFun1(arg) [builtins setObject:^(NSArray* args) { \
return [NSNumber numberWithDouble:arg([arg1 doubleValue])]; \
} forKey:@"" #arg ""];
#define addFun2(arg) [builtins setObject:^(NSArray* args) { \
return [NSNumber numberWithDouble:arg([arg1 doubleValue], [arg2 doubleValue])]; \
} forKey:@"" #arg ""];
#define boolResult(arg) (arg ? num(1) : num(0))

    OEnv* builtins = [[OEnv alloc] initWithOuterEnv:nil];
    addBinaryOp(+)  addBinaryOp(*)
    addBinaryOp(-)  addBinaryOp(/)
    addBinaryOp(>)  addBinaryOp(<)
    addBinaryOp(>=) addBinaryOp(<=)
    addFun1(sin)  addFun1(cos) addFun1(tan)
    addFun1(exp)  addFun1(log) addFun1(log10)
    addFun2(pow)  addFun1(sqrt) addFun1(ceil)
    addFun1(fabs) addFun1(floor) addFun2(fmod)
    [builtins setObject:^(NSArray* args) { return boolResult(![arg1 doubleValue]); } forKey:@"not"];
    [builtins setObject:^(NSArray* args) { return boolResult([arg1 isEqual:arg2]); } forKey:@"equal?"];
    [builtins setObject:^(NSArray* args) { return num([arg1 count]); } forKey:@"length"];
    [builtins setObject:^(NSArray* args) {
        return [[NSArray arrayWithObject:arg1] arrayByAddingObjectsFromArray:arg2];
    } forKey:@"cons"];
    [builtins setObject:^(NSArray* args) {
        NSArray* arr = arg1;
        return [arr count] ? [arr objectAtIndex:0] : nil;
    } forKey:@"car"];
    [builtins setObject:^(NSArray* args) {
        NSArray* arr = arg1;
        return [arg1 count] ? [arr subarrayWithRange:NSMakeRange(1,[arr count]-1)] : [NSArray array];
    } forKey:@"cdr"];
    [builtins setObject:^(NSArray* args) { NSLog(@"%@", arg1); return nil; } forKey:@"print"];
    [builtins setObject:^(NSArray* args) { return [arg1 arrayByAddingObjectsFromArray:arg2]; } forKey:@"append"];
    [builtins setObject:^(NSArray* args) { return args; } forKey:@"list"];
    [builtins setObject:^(NSArray* args) { return num([arg1 isKindOfClass:[NSArray class]]); } forKey:@"list?"];
    [builtins setObject:^(NSArray* args) { return num([arg1 count] == 0); } forKey:@"null?"];
    [builtins setObject:^(NSArray* args) { return num([arg1 isKindOfClass:[NSString class]]); }  forKey:@"symbol?"];
    return builtins;
}

- (void)test {
    NSArray* tokens = [self tokenize:
                       @"(begin "
                       "(define mult (lambda (x y) (* x y)))"
                       "(define zero (sin (* 0.5 3.1459)))"
                       "(define fact (lambda (n) (if (<= n 1) 1 (* n (fact (- n 1))))))"
                       "(equal? (cons 3 (append (list 1) (list 2))) (quote 3 2 1))"
                         "(print (fact 50))"
                         "(define first car)"
                         "(define rest cdr)"
                         "(define count (lambda (item L) (if L (+ (equal? item (first L)) (count item (rest L))) 0)))"
                         "(print (count 0 (list 0 1 2 3 0 0)))"
                         "(print (quote (count (quote the) (quote (the more the merrier the bigger the better)))))"
                         "(print (count (quote the) (quote (the more the merrier the bigger the better))))"
                         "(print (quote (testing 1 (2.0) -3.14e159)))"
                         "(define twice (lambda (x) (* 2 x)))"
                         "(define compose (lambda (f g) (lambda (x) (f (g x)))))"
                         "(define repeat (lambda (f) (compose f f)))"
                         "((repeat (repeat twice)) 5)"
                         "(define abs (lambda (n) ((if (> n 0) + -) 0 n)))"
                         "(print (list (abs -3) (abs 0) (abs 3)))"
                         "(define combine (lambda (f)"
                         "(lambda (x y)"
                         "(if (null? x) (quote ())"
                         "(f (list (car x) (car y))"
                         "((combine f) (cdr x) (cdr y)))))))"
                         "(define zip (combine cons))"
                         "(print (zip (list 1 2 3 4) (list 5 6 7 8)))"
                         "(define riff-shuffle (lambda (deck) (begin"
                         "(define take (lambda (n seq) (if (<= n 0) (quote ()) (cons (car seq) (take (- n 1) (cdr seq))))))"
                         "(define drop (lambda (n seq) (if (<= n 0) seq (drop (- n 1) (cdr seq)))))"
                         "(define mid (lambda (seq) (/ (length seq) 2)))"
                         "((combine append) (take (mid deck) deck) (drop (mid deck) deck)))))"
                         "(print (riff-shuffle (list 1 2 3 4 5 6 7 8)))"
//                       "NSArray"
                       @")"
                       ];
    NSObject* exp = [self expression:[NSMutableArray arrayWithArray:tokens]];
    OEnv* env = [self builtins];
    NSObject* result = [self eval:exp env:env];
    NSLog(@"result: %@", result);
}

@end
