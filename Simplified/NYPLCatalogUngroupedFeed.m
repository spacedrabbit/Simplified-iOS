#import "NYPLAsync.h"
#import "NYPLBook.h"
#import "NYPLBookRegistry.h"
#import "NYPLCatalogFacet.h"
#import "NYPLCatalogFacetGroup.h"
#import "NYPLOPDS.h"
#import "NYPLOpenSearchDescription.h"

#import "NYPLCatalogUngroupedFeed.h"

@interface NYPLCatalogUngroupedFeed ()

@property (nonatomic) BOOL currentlyFetchingNextURL;
@property (nonatomic) NSArray *books;
@property (nonatomic) NSArray *facetGroups;
@property (nonatomic) NSUInteger greatestPreparationIndex;
@property (nonatomic) NSURL *nextURL;
@property (nonatomic) NSURL *openSearchURL;
@property (nonatomic) NSString *searchTemplate;
@property (nonatomic) NSString *title;

@end

// If fewer than this many books are currently available when |prepareForBookIndex:| is called, an
// attempt to fetch more books will be made.
static NSUInteger const preloadThreshold = 100;

@implementation NYPLCatalogUngroupedFeed

+ (void)withURL:(NSURL *)URL
includingSearchTemplate:(BOOL)includingSearchTemplate
handler:(void (^)(NYPLCatalogUngroupedFeed *category))handler
{
  if(!handler) {
    @throw NSInvalidArgumentException;
  }
  
  [NYPLOPDSFeed
   withURL:URL
   completionHandler:^(NYPLOPDSFeed *const ungroupedFeed) {
     if(!ungroupedFeed) {
       NYPLLOG(@"Failed to retrieve acquisition feed.");
       NYPLAsyncDispatch(^{handler(nil);});
       return;
     }
     
     NSMutableArray *const books = [NSMutableArray arrayWithCapacity:ungroupedFeed.entries.count];
     
     for(NYPLOPDSEntry *const entry in ungroupedFeed.entries) {
       NYPLBook *const book = [NYPLBook bookWithEntry:entry];
       if(!book) {
         NYPLLOG(@"Failed to create book from entry.");
         continue;
       }
       [[NYPLBookRegistry sharedRegistry] updateBook:book];
       [books addObject:book];
     }
     
     NSMutableArray *const facetGroupNames = [NSMutableArray array];
     NSMutableDictionary *const facetGroupNamesToMutableFacetArrays =
       [NSMutableDictionary dictionary];
     NSURL *nextURL = nil;
     NSURL *openSearchURL = nil;
     
     for(NYPLOPDSLink *const link in ungroupedFeed.links) {
       if([link.rel isEqualToString:NYPLOPDSRelationFacet]) {
         NSString *groupName = nil;
         for(NSString *const key in link.attributes) {
           if(NYPLOPDSAttributeKeyStringIsFacetGroup(key)) {
             groupName = link.attributes[key];
             break;
           }
         }
         if(!groupName) {
           NYPLLOG(@"Ignoring facet without group due to UI limitations.");
           continue;
         }
         NYPLCatalogFacet *const facet = [NYPLCatalogFacet catalogFacetWithLink:link];
         if(!facet) {
           NYPLLOG(@"Ignoring invalid facet link.");
           continue;
         }
         if(![facetGroupNames containsObject:groupName]) {
           [facetGroupNames addObject:groupName];
           facetGroupNamesToMutableFacetArrays[groupName] = [NSMutableArray arrayWithCapacity:2];
         }
         [facetGroupNamesToMutableFacetArrays[groupName] addObject:facet];
         continue;
       }
       if([link.rel isEqualToString:NYPLOPDSRelationPaginationNext]) {
         nextURL = link.href;
         continue;
       }
       if([link.rel isEqualToString:NYPLOPDSRelationSearch] &&
          NYPLOPDSTypeStringIsOpenSearchDescription(link.type)) {
         openSearchURL = link.href;
         continue;
       }
     }
     
     // Care is taken to preserve facet and facet group order from the original feed.
     NSMutableArray *const facetGroups = [NSMutableArray arrayWithCapacity:facetGroupNames.count];
     for(NSString *const facetGroupName in facetGroupNames) {
       [facetGroups addObject:[[NYPLCatalogFacetGroup alloc]
                               initWithFacets:facetGroupNamesToMutableFacetArrays[facetGroupName]
                               name:facetGroupName]];
     }
     
     if(openSearchURL && includingSearchTemplate) {
       [NYPLOpenSearchDescription
        withURL:openSearchURL
        completionHandler:^(NYPLOpenSearchDescription *const description) {
          if(!description) {
            NYPLLOG(@"Failed to retrieve open search description.");
          }
          NYPLAsyncDispatch(^{handler([[NYPLCatalogUngroupedFeed alloc]
                                       initWithBooks:books
                                       facetGroups:facetGroups
                                       nextURL:nextURL
                                       searchTemplate:description.OPDSURLTemplate
                                       title:ungroupedFeed.title]);});
        }];
      } else {
        NYPLAsyncDispatch(^{handler([[NYPLCatalogUngroupedFeed alloc]
                                     initWithBooks:books
                                     facetGroups:facetGroups
                                     nextURL:nextURL
                                     searchTemplate:nil
                                     title:ungroupedFeed.title]);});
      }
   }];
}

+ (void)withURL:(NSURL *)URL
        handler:(void (^)(NYPLCatalogUngroupedFeed *category))handler
{
  [self withURL:URL includingSearchTemplate:YES handler:handler];
}

- (instancetype)initWithOPDSFeed:(NYPLOPDSFeed *const)feed
{
  if(feed.type != NYPLOPDSFeedTypeAcquisitionUngrouped) {
    @throw NSInvalidArgumentException;
  }
  
  NSMutableArray *const books = [NSMutableArray arrayWithCapacity:feed.entries.count];
  
  for(NYPLOPDSEntry *const entry in feed.entries) {
    NYPLBook *const book = [NYPLBook bookWithEntry:entry];
    if(!book) {
      NYPLLOG(@"Failed to create book from entry.");
      continue;
    }
    [[NYPLBookRegistry sharedRegistry] updateBook:book];
    [books addObject:book];
  }
  
  NSMutableArray *const facetGroupNames = [NSMutableArray array];
  NSMutableDictionary *const facetGroupNamesToMutableFacetArrays =
    [NSMutableDictionary dictionary];
  NSURL *nextURL = nil;
  
  for(NYPLOPDSLink *const link in feed.links) {
    if([link.rel isEqualToString:NYPLOPDSRelationFacet]) {
      NSString *groupName = nil;
      for(NSString *const key in link.attributes) {
        if(NYPLOPDSAttributeKeyStringIsFacetGroup(key)) {
          groupName = link.attributes[key];
          break;
        }
      }
      if(!groupName) {
        NYPLLOG(@"Ignoring facet without group due to UI limitations.");
        continue;
      }
      NYPLCatalogFacet *const facet = [NYPLCatalogFacet catalogFacetWithLink:link];
      if(!facet) {
        NYPLLOG(@"Ignoring invalid facet link.");
        continue;
      }
      if(![facetGroupNames containsObject:groupName]) {
        [facetGroupNames addObject:groupName];
        facetGroupNamesToMutableFacetArrays[groupName] = [NSMutableArray arrayWithCapacity:2];
      }
      [facetGroupNamesToMutableFacetArrays[groupName] addObject:facet];
      continue;
    }
    if([link.rel isEqualToString:NYPLOPDSRelationPaginationNext]) {
      nextURL = link.href;
      continue;
    }
    if([link.rel isEqualToString:NYPLOPDSRelationSearch] &&
       NYPLOPDSTypeStringIsOpenSearchDescription(link.type)) {
      self.openSearchURL = link.href;
      continue;
    }
  }
  
  // Care is taken to preserve facet and facet group order from the original feed.
  NSMutableArray *const facetGroups = [NSMutableArray arrayWithCapacity:facetGroupNames.count];
  for(NSString *const facetGroupName in facetGroupNames) {
    [facetGroups addObject:[[NYPLCatalogFacetGroup alloc]
                            initWithFacets:facetGroupNamesToMutableFacetArrays[facetGroupName]
                            name:facetGroupName]];
  }

  return self;
}

- (instancetype)initWithBooks:(NSArray *const)books
                  facetGroups:(NSArray *const)facetGroups
                      nextURL:(NSURL *const)nextURL
               searchTemplate:(NSString *const)searchTemplate
                        title:(NSString *const)title
{
  self = [super init];
  if(!self) return nil;
  
  if(!(books && facetGroups && title)) {
    @throw NSInvalidArgumentException;
  }
  
  for(id const object in books) {
    if(![object isKindOfClass:[NYPLBook class]]) {
      @throw NSInvalidArgumentException;
    }
  }
  
  for(id const object in facetGroups) {
    if(![object isKindOfClass:[NYPLCatalogFacetGroup class]]) {
      @throw NSInvalidArgumentException;
    }
  }
  
  self.books = books;
  self.facetGroups = facetGroups;
  self.nextURL = nextURL;
  self.searchTemplate = searchTemplate;
  self.title = title;
  
  [[NSNotificationCenter defaultCenter]
   addObserver:self
   selector:@selector(refreshBooks)
   name:NYPLBookRegistryDidChangeNotification
   object:nil];
  
  return self;
}

- (void)prepareForBookIndex:(NSUInteger)bookIndex
{
  if(bookIndex >= self.books.count) {
    @throw NSInvalidArgumentException;
  }
  
  if(bookIndex < self.greatestPreparationIndex) {
    return;
  }
  
  self.greatestPreparationIndex = bookIndex;
  
  if(self.currentlyFetchingNextURL) return;
  
  if(!self.nextURL) return;
  
  if(self.books.count - bookIndex > preloadThreshold) {
    return;
  }
  
  self.currentlyFetchingNextURL = YES;
  
  NSUInteger const location = self.books.count;
  
  [NYPLCatalogUngroupedFeed
   withURL:self.nextURL
   includingSearchTemplate:NO
   handler:^(NYPLCatalogUngroupedFeed *const ungroupedFeed) {
     [[NSOperationQueue mainQueue] addOperationWithBlock:^{
       if(!ungroupedFeed) {
         NYPLLOG(@"Failed to fetch next page.");
         self.currentlyFetchingNextURL = NO;
         return;
       }
       
       NSMutableArray *const books = [self.books mutableCopy];
       [books addObjectsFromArray:ungroupedFeed.books];
       self.books = books;
       self.nextURL = ungroupedFeed.nextURL;
       self.currentlyFetchingNextURL = NO;
       
       [self prepareForBookIndex:self.greatestPreparationIndex];
       
       NSRange const range = {.location = location, .length = ungroupedFeed.books.count};
       
       [self.delegate catalogUngroupedFeed:self
                               didAddBooks:ungroupedFeed.books
                                     range:range];
     }];
   }];
}

- (void)refreshBooks
{
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    NSMutableArray *const refreshedBooks = [NSMutableArray arrayWithCapacity:self.books.count];
    
    for(NYPLBook *const book in self.books) {
      NYPLBook *const refreshedBook = [[NYPLBookRegistry sharedRegistry]
                                       bookForIdentifier:book.identifier];
      if(refreshedBook) {
        [refreshedBooks addObject:refreshedBook];
      } else {
        [refreshedBooks addObject:book];
      }
    }
    
    self.books = refreshedBooks;
    
    [self.delegate catalogUngroupedFeed:self didUpdateBooks:self.books];
  }];
}

#pragma mark NSObject

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
