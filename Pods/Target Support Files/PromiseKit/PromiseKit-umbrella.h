#ifdef __OBJC__
#import <UIKit/UIKit.h>
#else
#ifndef FOUNDATION_EXPORT
#if defined(__cplusplus)
#define FOUNDATION_EXPORT extern "C"
#else
#define FOUNDATION_EXPORT extern
#endif
#endif
#endif

#import <PromiseKit/fwd.h>
#import <PromiseKit/AnyPromise.h>
#import <PromiseKit/PromiseKit.h>
#import <PromiseKit/NSURLSession+AnyPromise.h>
#import <PromiseKit/NSTask+AnyPromise.h>
#import <PromiseKit/NSNotificationCenter+AnyPromise.h>
#import <PromiseKit/PMKFoundation.h>
#import <PromiseKit/PMKUIKit.h>
#import <PromiseKit/UIView+AnyPromise.h>
#import <PromiseKit/UIViewController+AnyPromise.h>

FOUNDATION_EXPORT double PromiseKitVersionNumber;
FOUNDATION_EXPORT const unsigned char PromiseKitVersionString[];

