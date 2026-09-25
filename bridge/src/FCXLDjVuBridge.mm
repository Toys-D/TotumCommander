#import "FCXLDjVuBridge.h"
#include <libdjvu/ddjvuapi.h>
#include <stdlib.h>
#include <math.h>

static NSString *const FCXLDjVuErrorDomain = @"com.fcxl.djvu";

/// DjVuLibre decodes asynchronously and reports progress/errors through a message queue.
/// Every blocking wait has to drain that queue or decoding never advances — this is the
/// one structural difference from the MuPDF bridge, which is synchronous.
///
/// Waiting is a POLL and not ddjvu_message_wait(), on purpose. The queue belongs to the
/// context, not to the caller: if a second thread drains it first, the message this caller
/// is waiting for is already gone and ddjvu_message_wait() never returns. That is exactly
/// how the whole program froze — the main thread stood inside it for good. Every entry
/// point is serialised now, and this ceiling is the second lock on the same door: a missed
/// message costs a slow page, never a dead program.
static bool fcxl_djvu_pump(ddjvu_context_t *ctx, bool wait, double timeout_seconds) {
    if (wait) {
        double waited = 0;
        while (!ddjvu_message_peek(ctx)) {
            if (waited >= timeout_seconds) return false;
            usleep(2000);
            waited += 0.002;
        }
    }
    while (ddjvu_message_peek(ctx)) {
        ddjvu_message_pop(ctx);
    }
    return true;
}

/// Как долго ждать одну страницу. Настоящая страница декодируется десятки миллисекунд;
/// двадцать секунд — это «уже никогда», и лучше вернуть пустоту, чем повесить программу.
static const double kFCXLDjVuTimeout = 20.0;

@implementation FCXLDjVuReader {
    ddjvu_context_t *_ctx;
    ddjvu_document_t *_doc;
    ddjvu_format_t *_fmt;
    int _pageCount;
}

- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    _ctx = ddjvu_context_create("TotumComXL");
    if (!_ctx) {
        if (error) *error = [NSError errorWithDomain:FCXLDjVuErrorDomain code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Failed to create DjVu context"}];
        return nil;
    }

    // fileSystemRepresentation is UTF-8 on macOS; the _utf8 variant avoids the locale
    // re-encoding the plain ddjvu_document_create_by_filename() would apply, which
    // mangles Cyrillic names.
    _doc = ddjvu_document_create_by_filename_utf8(_ctx, [path fileSystemRepresentation], 1);
    if (!_doc) {
        if (error) *error = [NSError errorWithDomain:FCXLDjVuErrorDomain code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"Failed to open DjVu document"}];
        [self close];
        return nil;
    }

    while (!ddjvu_document_decoding_done(_doc)) {
        if (!fcxl_djvu_pump(_ctx, true, kFCXLDjVuTimeout)) break;
    }
    if (ddjvu_document_decoding_error(_doc)) {
        if (error) *error = [NSError errorWithDomain:FCXLDjVuErrorDomain code:3
                                            userInfo:@{NSLocalizedDescriptionKey: @"DjVu document is damaged or unsupported"}];
        [self close];
        return nil;
    }

    _pageCount = ddjvu_document_get_pagenum(_doc);
    if (_pageCount <= 0) {
        if (error) *error = [NSError errorWithDomain:FCXLDjVuErrorDomain code:4
                                            userInfo:@{NSLocalizedDescriptionKey: @"DjVu document has no pages"}];
        [self close];
        return nil;
    }

    // RGBA8888 with alpha last — the exact layout the viewer's CGImage expects.
    // The 4th value is an XOR applied to every pixel, NOT an alpha mask: DjVu has no
    // alpha channel, so without forcing the top byte to 0xff every page would decode
    // fully transparent.
    unsigned int masks[4] = {0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000};
    _fmt = ddjvu_format_create(DDJVU_FORMAT_RGBMASK32, 4, masks);
    if (!_fmt) {
        if (error) *error = [NSError errorWithDomain:FCXLDjVuErrorDomain code:5
                                            userInfo:@{NSLocalizedDescriptionKey: @"Failed to create DjVu pixel format"}];
        [self close];
        return nil;
    }
    // DjVu stores rows bottom-up by default; CGImage reads them top-down.
    ddjvu_format_set_row_order(_fmt, 1);

    return self;
}

- (void)dealloc {
    [self close];
}

- (NSInteger)pageCount {
    return (NSInteger)_pageCount;
}

/// Page geometry without decoding the whole page. Returns false if it never resolves.
- (BOOL)infoForPage:(NSInteger)index into:(ddjvu_pageinfo_t *)info {
    @synchronized (self) {
        if (!_ctx || !_doc || index < 0 || index >= _pageCount) return NO;
        ddjvu_status_t status;
        while ((status = ddjvu_document_get_pageinfo(_doc, (int)index, info)) < DDJVU_JOB_OK) {
            if (!fcxl_djvu_pump(_ctx, true, kFCXLDjVuTimeout)) return NO;
        }
        return status == DDJVU_JOB_OK;
    }
}

- (CGSize)pageSizeAtIndex:(NSInteger)index {
    ddjvu_pageinfo_t info;
    if (![self infoForPage:index into:&info]) return CGSizeZero;
    // info is in pixels at its own dpi — convert to 72-dpi points to match the PDF path.
    int dpi = info.dpi > 0 ? info.dpi : 300;
    return CGSizeMake((CGFloat)info.width * 72.0 / (CGFloat)dpi,
                      (CGFloat)info.height * 72.0 / (CGFloat)dpi);
}

/// Одна страница за раз, на весь документ.
///
/// Очередь сообщений одна на контекст, и два потока, качающих её одновременно, воруют
/// сообщения друг у друга. Полоса миниатюр и лента страниц делают ровно это — каждая в
/// своём потоке, — и книга вставала намертво. Замок здесь, у самого ридера, а не у каждого
/// вызывающего: тогда безопасен любой путь, включая те, которых ещё нет.
- (nullable NSDictionary<NSString*, id> *)renderPageAtIndex:(NSInteger)index scale:(CGFloat)scale {
    @synchronized (self) {
    if (!_ctx || !_doc || !_fmt || index < 0 || index >= _pageCount) return nil;
    if (scale <= 0) scale = 1.0;

    CGSize points = [self pageSizeAtIndex:index];
    if (points.width <= 0 || points.height <= 0) return nil;

    int w = (int)lround(points.width * scale);
    int h = (int)lround(points.height * scale);
    if (w <= 0 || h <= 0) return nil;

    ddjvu_page_t *page = ddjvu_page_create_by_pageno(_doc, (int)index);
    if (!page) return nil;
    while (!ddjvu_page_decoding_done(page)) {
        if (!fcxl_djvu_pump(_ctx, true, kFCXLDjVuTimeout)) {
            ddjvu_page_release(page);
            return nil;
        }
    }
    if (ddjvu_page_decoding_error(page)) {
        ddjvu_page_release(page);
        return nil;
    }

    ddjvu_rect_t rect;
    rect.x = 0;
    rect.y = 0;
    rect.w = (unsigned int)w;
    rect.h = (unsigned int)h;

    unsigned long stride = (unsigned long)w * 4;
    size_t bytes = (size_t)stride * (size_t)h;
    char *buffer = (char *)calloc(1, bytes);
    if (!buffer) {
        ddjvu_page_release(page);
        return nil;
    }

    NSDictionary *result = nil;
    // Render the full page (pagerect) and copy all of it (renderrect) into the buffer.
    if (ddjvu_page_render(page, DDJVU_RENDER_COLOR, &rect, &rect, _fmt, stride, buffer)) {
        result = @{
            @"data": [NSData dataWithBytes:buffer length:(NSUInteger)bytes],
            @"width": @(w),
            @"height": @(h),
            @"stride": @((NSInteger)stride)
        };
    }

    free(buffer);
    ddjvu_page_release(page);
    return result;
    }
}

- (void)close {
    @synchronized (self) {
    if (_fmt) {
        ddjvu_format_release(_fmt);
        _fmt = NULL;
    }
    if (_doc) {
        ddjvu_document_release(_doc);
        _doc = NULL;
    }
    if (_ctx) {
        ddjvu_context_release(_ctx);
        _ctx = NULL;
    }
    _pageCount = 0;
    }
}

@end
