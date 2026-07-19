// chc_swift.h — Swift bridge for clickhouse-c.
//
// Provides simple C functions that perform type parsing, block reading,
// and block writing, returning results in plain C types that Swift can
// consume without needing to see the opaque struct definitions.

#ifndef chc_swift_h
#define chc_swift_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Type parsing
// ---------------------------------------------------------------------------

// Parse a ClickHouse type name. Returns a handle (opaque pointer), or NULL
// on error. The handle must be freed with chc_swift_type_free().
void *chc_swift_type_parse(const char *name, size_t name_len, char *err_buf, size_t err_cap);

// Free a type handle returned by chc_swift_type_parse().
void chc_swift_type_free(void *type_handle);

// Get the kind integer of a type handle.
int chc_swift_type_kind(void *type_handle);

// Get the formatted type name. Returns a pointer into the handle's storage
// (valid until the handle is freed). Sets *out_len to the string length.
const char *chc_swift_type_name(void *type_handle, size_t *out_len);

// Get the number of child types.
size_t chc_swift_type_n_children(void *type_handle);

// Get a child type handle (borrowed, do not free).
void *chc_swift_type_child(void *type_handle, size_t i);

// ---------------------------------------------------------------------------
// Block reading
// ---------------------------------------------------------------------------

// Read one block from native format bytes in memory.
// Returns a block handle, or NULL on EOF or error.
// On error, fills err_buf with a message.
// The handle must be freed with chc_swift_block_free().
void *chc_swift_block_read(const void *data, size_t data_len,
                           int has_block_info,
                           char *err_buf, size_t err_cap);

// Free a block handle.
void chc_swift_block_free(void *block_handle);

// Block info
size_t chc_swift_block_n_rows(void *block_handle);
size_t chc_swift_block_n_columns(void *block_handle);

// Column info (borrowed pointers — valid until block is freed)
const char *chc_swift_block_col_name(void *block_handle, size_t col_idx, size_t *out_len);
void       *chc_swift_block_col_type(void *block_handle, size_t col_idx);

// Column data access
// Returns a column handle (borrowed, do not free).
void *chc_swift_block_col_data(void *block_handle, size_t col_idx);

// ---------------------------------------------------------------------------
// Column data access (on borrowed column handles)
// ---------------------------------------------------------------------------

// Column layout kind (CHC_COL_FIXED=1, CHC_COL_STRING=2, etc.)
int chc_swift_col_layout(void *col_handle);
size_t chc_swift_col_n_rows(void *col_handle);

// FIXED: get pointer to data and element size.
const void *chc_swift_col_fixed_data(void *col_handle, size_t *elem_size);

// STRING: get pointer to data and offsets arrays.
const uint8_t  *chc_swift_col_string_data(void *col_handle);
const uint64_t *chc_swift_col_string_offsets(void *col_handle);

// NULLABLE
const uint8_t *chc_swift_col_null_map(void *col_handle);
void           *chc_swift_col_nullable_inner(void *col_handle);

// ARRAY
const uint64_t *chc_swift_col_array_offsets(void *col_handle);
void            *chc_swift_col_array_values(void *col_handle);

// TUPLE
size_t chc_swift_col_tuple_arity(void *col_handle);
void   *chc_swift_col_tuple_child(void *col_handle, size_t i);

// LOW_CARDINALITY
int            chc_swift_col_lc_key_size(void *col_handle);
const void    *chc_swift_col_lc_keys(void *col_handle);
void           *chc_swift_col_lc_dict(void *col_handle);

#ifdef __cplusplus
}
#endif

#endif /* chc_swift_h */
