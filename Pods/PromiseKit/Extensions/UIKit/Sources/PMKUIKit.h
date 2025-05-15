#import <PromiseKit/UIView+AnyPromise.h>
#import <PromiseKit/UIViewController+AnyPromise.h>

typedef NS_OPTIONS(NSInteger, PMKAnimationOptions) {
    PMKAnimationOptionsNone = 1 << 0,
    PMKAnimationOptionsAppear = 1 << 1,
    PMKAnimationOptionsDisappear = 1 << 2,
};
