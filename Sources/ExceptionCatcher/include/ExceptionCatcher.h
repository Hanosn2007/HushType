#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL HTCatchException(NS_NOESCAPE void (^block)(void), NSError **error);

NS_ASSUME_NONNULL_END
