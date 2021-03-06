typedef NS_ENUM(NSInteger, NYPLBookState) {
  NYPLBookStateUnregistered       = 1 << 0,
  NYPLBookStateDownloadNeeded     = 1 << 1,
  NYPLBookStateDownloading        = 1 << 2,
  NYPLBookStateDownloadFailed     = 1 << 3,
  NYPLBookStateDownloadSuccessful = 1 << 4,
  NYPLBookStateHolding            = 1 << 5,
  NYPLBookStateUsed               = 1 << 6
};

NYPLBookState NYPLBookStateFromString(NSString *string);

NSString *NYPLBookStateToString(NYPLBookState state);