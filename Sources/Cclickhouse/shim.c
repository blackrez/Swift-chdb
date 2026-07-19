// Exactly one TU must define CHC_IMPLEMENTATION.
#define CHC_IMPLEMENTATION
#include "clickhouse.h"
#include <stdlib.h>
#include <string.h>

// =========================================================================
// Allocator helpers  (must be before chc_swift.h inclusion)
// =========================================================================

static void *chc_swift_alloc_fn(void *ud, size_t bytes) {
    (void)ud;
    return malloc(bytes);
}

static void *chc_swift_realloc_fn(void *ud, void *p, size_t old, size_t new_) {
    (void)ud; (void)old;
    return realloc(p, new_);
}

static void chc_swift_free_fn(void *ud, void *p, size_t bytes) {
    (void)ud; (void)bytes;
    free(p);
}

static const chc_alloc chc_swift_allocator_inst = {
    NULL, chc_swift_alloc_fn, chc_swift_realloc_fn, chc_swift_free_fn
};

#define ALLOC (&chc_swift_allocator_inst)

// =========================================================================
// Swift bridge — wraps clickhouse-c ops in plain-C functions.
// =========================================================================

#include "chc_swift.h"

// --- Type parsing ---

void *chc_swift_type_parse(const char *name, size_t name_len,
                           char *err_buf, size_t err_cap) {
    chc_type *out = NULL;
    chc_err err;
    int rc = chc_type_parse(name, name_len, ALLOC, &out, &err);
    if (rc != CHC_OK || !out) {
        if (err_buf && err_cap) {
            size_t n = strlen(err.msg);
            if (n >= err_cap) n = err_cap - 1;
            memcpy(err_buf, err.msg, n);
            err_buf[n] = '\0';
        }
        return NULL;
    }
    return (void *)out;
}

void chc_swift_type_free(void *type_handle) {
    if (type_handle) chc_type_destroy((chc_type *)type_handle, ALLOC);
}

int chc_swift_type_kind(void *type_handle) {
    return type_handle ? (int)chc_type_kind((const chc_type *)type_handle) : 0;
}

const char *chc_swift_type_name(void *type_handle, size_t *out_len) {
    if (!type_handle) { *out_len = 0; return NULL; }
    return chc_type_name((const chc_type *)type_handle, out_len);
}

size_t chc_swift_type_n_children(void *type_handle) {
    return type_handle ? chc_type_n_children((const chc_type *)type_handle) : 0;
}

void *chc_swift_type_child(void *type_handle, size_t i) {
    if (!type_handle) return NULL;
    return (void *)chc_type_child((const chc_type *)type_handle, i);
}

// --- Block reading ---

void *chc_swift_block_read(const void *data, size_t data_len,
                           int has_block_info,
                           char *err_buf, size_t err_cap) {
    chc_block_opts opts;
    memset(&opts, 0, sizeof(opts));
    opts.has_block_info = has_block_info ? true : false;

    chc_in in;
    chc_err err;
    int rc = chc_in_init_ioless(&in, ALLOC);
    if (rc != CHC_OK) {
        if (err_buf && err_cap) snprintf(err_buf, err_cap, "chc_in_init_ioless failed");
        return NULL;
    }

    rc = chc_in_submit(&in, data, data_len, &err);
    if (rc != CHC_OK) {
        if (err_buf && err_cap) {
            size_t n = strlen(err.msg);
            if (n >= err_cap) n = err_cap - 1;
            memcpy(err_buf, err.msg, n);
            err_buf[n] = '\0';
        }
        chc_in_free(&in);
        return NULL;
    }

    chc_block *block = NULL;
    rc = chc_block_read(&in, ALLOC, &opts, &block, &err);
    chc_in_free(&in);

    if (rc == CHC_ERR_EOF || (rc == CHC_OK && !block)) {
        return NULL; // clean EOF (not an error)
    }
    if (rc != CHC_OK || !block) {
        if (err_buf && err_cap) {
            size_t n = strlen(err.msg);
            if (n >= err_cap) n = err_cap - 1;
            memcpy(err_buf, err.msg, n);
            err_buf[n] = '\0';
        }
        return NULL;
    }
    return (void *)block;
}

void chc_swift_block_free(void *block_handle) {
    if (block_handle) chc_block_destroy((chc_block *)block_handle, ALLOC);
}

size_t chc_swift_block_n_rows(void *block_handle) {
    return block_handle ? chc_block_n_rows((const chc_block *)block_handle) : 0;
}

size_t chc_swift_block_n_columns(void *block_handle) {
    return block_handle ? chc_block_n_columns((const chc_block *)block_handle) : 0;
}

const char *chc_swift_block_col_name(void *block_handle, size_t col_idx, size_t *out_len) {
    if (!block_handle) { *out_len = 0; return NULL; }
    return chc_block_column_name((const chc_block *)block_handle, col_idx, out_len);
}

void *chc_swift_block_col_type(void *block_handle, size_t col_idx) {
    if (!block_handle) return NULL;
    return (void *)chc_block_column_type((const chc_block *)block_handle, col_idx);
}

void *chc_swift_block_col_data(void *block_handle, size_t col_idx) {
    if (!block_handle) return NULL;
    return (void *)chc_block_column((const chc_block *)block_handle, col_idx);
}

// --- Column data access ---

int chc_swift_col_layout(void *col_handle) {
    return col_handle ? (int)chc_column_layout((const chc_column *)col_handle) : 0;
}

size_t chc_swift_col_n_rows(void *col_handle) {
    return col_handle ? chc_column_n_rows((const chc_column *)col_handle) : 0;
}

const void *chc_swift_col_fixed_data(void *col_handle, size_t *elem_size) {
    if (!col_handle) { *elem_size = 0; return NULL; }
    return chc_column_fixed_data((const chc_column *)col_handle, elem_size);
}

const uint8_t *chc_swift_col_string_data(void *col_handle) {
    return col_handle ? chc_column_string_data((const chc_column *)col_handle) : NULL;
}

const uint64_t *chc_swift_col_string_offsets(void *col_handle) {
    return col_handle ? chc_column_string_offsets((const chc_column *)col_handle) : NULL;
}

const uint8_t *chc_swift_col_null_map(void *col_handle) {
    return col_handle ? chc_column_null_map((const chc_column *)col_handle) : NULL;
}

void *chc_swift_col_nullable_inner(void *col_handle) {
    return col_handle ? (void *)chc_column_nullable_inner((const chc_column *)col_handle) : NULL;
}

const uint64_t *chc_swift_col_array_offsets(void *col_handle) {
    return col_handle ? chc_column_array_offsets((const chc_column *)col_handle) : NULL;
}

void *chc_swift_col_array_values(void *col_handle) {
    return col_handle ? (void *)chc_column_array_values((const chc_column *)col_handle) : NULL;
}

size_t chc_swift_col_tuple_arity(void *col_handle) {
    return col_handle ? chc_column_tuple_arity((const chc_column *)col_handle) : 0;
}

void *chc_swift_col_tuple_child(void *col_handle, size_t i) {
    return col_handle ? (void *)chc_column_tuple_child((const chc_column *)col_handle, i) : NULL;
}

int chc_swift_col_lc_key_size(void *col_handle) {
    return col_handle ? chc_column_lc_key_size((const chc_column *)col_handle) : 0;
}

const void *chc_swift_col_lc_keys(void *col_handle) {
    return col_handle ? chc_column_lc_keys((const chc_column *)col_handle) : NULL;
}

void *chc_swift_col_lc_dict(void *col_handle) {
    return col_handle ? (void *)chc_column_lc_dict((const chc_column *)col_handle) : NULL;
}
