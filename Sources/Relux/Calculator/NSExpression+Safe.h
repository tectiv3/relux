#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSExpression (Safe)

/// Evaluates an expression string, returning nil on any Obj-C exception.
/// This prevents NSExpression format errors or runtime failures from crashing Swift.
+ (nullable NSNumber *)relux_safeEvaluateExpression:(NSString *)expressionString;

@end

NS_ASSUME_NONNULL_END
