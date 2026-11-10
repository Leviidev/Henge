/* Rebuild the selected White Rose photo after the initial GPU failure cached a
 * black image. Preparation is read-only; apply requires exact old/new hashes.
 * clang -target arm64-apple-macos14 -fobjc-arc -framework Foundation
 * -framework AppKit -framework CoreImage -framework Metal -framework OpenDirectory
 * repair_profile_photo.m -o repair-profile-photo
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <OpenDirectory/OpenDirectory.h>
#import <CommonCrypto/CommonDigest.h>
#include <unistd.h>
static NSString *hashData(NSData *data){unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,hash);NSMutableString *s=[NSMutableString new];for(unsigned i=0;i<sizeof(hash);i++)[s appendFormat:@"%02x",hash[i]];return s;}
int main(int argc,const char **argv){@autoreleasepool{
 if(argc!=3 && argc!=5){fprintf(stderr,"usage: repair-profile-photo prepare directory | apply directory old-sha256 new-sha256\n");return 2;}
 NSString *mode=@(argv[1]),*dir=@(argv[2]);NSError *error=nil;
 ODNode *node=[ODNode nodeWithSession:ODSession.defaultSession name:@"/Local/Default" error:&error];
 ODRecord *record=[node recordWithRecordType:kODRecordTypeUsers name:@"hengetest" attributes:@[kODAttributeTypePicture,kODAttributeTypeJPEGPhoto,kODAttributeTypeUniqueID] error:&error];
 NSArray *pictures=[record valuesForAttribute:kODAttributeTypePicture error:&error],*photos=[record valuesForAttribute:kODAttributeTypeJPEGPhoto error:&error];
 if(!record || error || pictures.count!=1 || photos.count!=1 || ![photos[0] isKindOfClass:NSData.class] || ![pictures[0] isEqual:@"/Library/User Pictures/Flowers/Whiterose.heic"]){fprintf(stderr,"Unexpected account/photo selection: %s\n",error.description.UTF8String?:"mismatch");return 3;}
 NSData *old=photos[0];NSString *candidatePath=[dir stringByAppendingPathComponent:@"candidate.jpg"];
 if([mode isEqual:@"prepare"] && argc==3){
  if(![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error])return 4;
  NSString *backup=[dir stringByAppendingPathComponent:@"original-attributes.plist"];
  if([[NSFileManager defaultManager] fileExistsAtPath:backup]){fprintf(stderr,"Backup exists; refusing to replace it\n");return 5;}
  NSDictionary *original=@{@"Picture":pictures,@"JPEGPhoto":photos,@"UniqueID":[record valuesForAttribute:kODAttributeTypeUniqueID error:nil]};
  NSData *backupData=[NSPropertyListSerialization dataWithPropertyList:original format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
  if(![backupData writeToFile:backup options:NSDataWritingWithoutOverwriting error:&error])return 6;
  NSData *source=[NSData dataWithContentsOfFile:pictures[0]];
  CIImage *image=[CIImage imageWithData:source options:@{kCIImageApplyOrientationProperty:@YES}];id<MTLDevice> device=MTLCreateSystemDefaultDevice();
  if(!image || !device || CGRectIsEmpty(image.extent))return 7;
  CGFloat scale=512.0/MIN(image.extent.size.width,image.extent.size.height);
  image=[image imageByApplyingTransform:CGAffineTransformMakeScale(scale,scale)];
  image=[image imageByApplyingTransform:CGAffineTransformMakeTranslation((512-image.extent.size.width)/2-image.extent.origin.x,(512-image.extent.size.height)/2-image.extent.origin.y)];
  NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:512 pixelsHigh:512 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:2048 bitsPerPixel:32];
  CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CIContext *context=[CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace:(__bridge id)cs,kCIContextOutputColorSpace:(__bridge id)cs}];
  [context render:image toBitmap:rep.bitmapData rowBytes:2048 bounds:CGRectMake(0,0,512,512) format:kCIFormatRGBA8 colorSpace:cs];CGColorSpaceRelease(cs);
  NSData *candidate=[rep representationUsingType:NSBitmapImageFileTypeJPEG properties:@{NSImageCompressionFactor:@0.95}];
  if(!candidate || ![candidate writeToFile:candidatePath options:NSDataWritingAtomic error:&error])return 8;
  NSDictionary *report=@{@"source_path":pictures[0],@"source_sha256":hashData(source),@"original_sha256":hashData(old),@"candidate_sha256":hashData(candidate),@"device":device.name,@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"status":@"prepared_not_applied"};
  NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];[json writeToFile:[dir stringByAppendingPathComponent:@"prepared.json"] atomically:YES];fwrite(json.bytes,1,json.length,stdout);return 0;
 }
 if([mode isEqual:@"apply"] && argc==5){
  NSData *candidate=[NSData dataWithContentsOfFile:candidatePath];
  if(geteuid()!=0 || !candidate || ![hashData(old) isEqual:@(argv[3])] || ![hashData(candidate) isEqual:@(argv[4])]){fprintf(stderr,"Privilege or old/new identity mismatch\n");return 9;}
  NSDictionary *backup=[NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"original-attributes.plist"]] options:NSPropertyListImmutable format:nil error:&error];
  if(![backup[@"JPEGPhoto"] isEqual:photos] || ![backup[@"Picture"] isEqual:pictures])return 10;
  if(![record setValue:candidate forAttribute:kODAttributeTypeJPEGPhoto error:&error] || ![record synchronizeAndReturnError:&error]){fprintf(stderr,"Write failed: %s\n",error.description.UTF8String);return 11;}
  NSArray *now=[record valuesForAttribute:kODAttributeTypeJPEGPhoto error:&error];
  BOOL match=now.count==1 && [now[0] isEqual:candidate] && [[record valuesForAttribute:kODAttributeTypePicture error:&error] isEqual:pictures];
  NSDictionary *receipt=@{@"status":match?@"applied_verified":@"verification_failed",@"original_sha256":hashData(old),@"candidate_sha256":hashData(candidate),@"picture_path":pictures[0]};NSData *json=[NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:nil];[json writeToFile:[dir stringByAppendingPathComponent:@"applied.json"] atomically:YES];fwrite(json.bytes,1,json.length,stdout);return match?0:12;
 }
 return 2;
}}
