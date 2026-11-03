#import <UIKit/UIKit.h>

// The Horizon page: Minecraft 26.3 rewritten in Rust (playhorizon.dev), its shared game files and
// its instances.
@interface HorizonViewController : UITableViewController
- (NSString *)imageName;
// Asks for a name and makes a Horizon instance (Instances > + > Horizon uses it too).
+ (void)promptNewInstanceFrom:(UIViewController *)presenter then:(void (^)(NSString *name))created;
@end
