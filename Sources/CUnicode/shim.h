#include <unicode/ustring.h>
static inline int32_t history_casefold(uint16_t *dest, int32_t capacity,
                                      const uint16_t *src, int32_t length,
                                      int32_t *status) {
    UErrorCode error = U_ZERO_ERROR;
    int32_t result = u_strFoldCase(dest, capacity, src, length, U_FOLD_CASE_DEFAULT, &error);
    *status = (int32_t)error;
    return result;
}
