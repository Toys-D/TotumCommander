#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// DjVu reader powered by DjVuLibre. Mirrors FCXLPDFReader's interface and returns the
/// same RGBA dictionary shape, so the viewer reuses one image-building path for both.
@interface FCXLDjVuReader : NSObject

/// Open a DjVu file. Returns nil on failure.
- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error;

/// Number of pages in the document.
@property (nonatomic, readonly) NSInteger pageCount;

/// Size of the page at index, in points (72 dpi) — same units as FCXLPDFReader, so the
/// viewer's layout maths is identical for PDF and DjVu.
- (CGSize)pageSizeAtIndex:(NSInteger)index;

/// Render page at index with the given scale factor.
/// Returns dictionary with keys: "data" (NSData, RGBA), "width", "height", "stride".
- (nullable NSDictionary<NSString*, id> *)renderPageAtIndex:(NSInteger)index scale:(CGFloat)scale;

/// Words of the page's hidden text layer, in reading order. Each is a dictionary: "text"
/// (NSString) and "x", "y", "w", "h" (NSNumber) — the word's box in page points (72 dpi) with
/// the origin at the TOP left, the same space the rendered page is laid out in. An empty
/// array means the page has no text layer (a plain scan) — there is nothing to search.
- (NSArray<NSDictionary<NSString*, id> *> *)wordsAtIndex:(NSInteger)index;

/// Close the document and free resources.
- (void)close;

@end

NS_ASSUME_NONNULL_END
