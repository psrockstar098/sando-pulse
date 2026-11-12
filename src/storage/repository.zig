//! Repository interface: ONE storage contract for every backend.
//! The in-memory store (dev default) and the PostgreSQL store both implement
//! this vtable, so the engine, API, and worker never know which backend is
//! behind them. Search returns documents owned by the caller's arena.

const std = @import("std");
const types = @import("../common/types.zig");

pub const Repository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Insert or replace a document (idempotent on content id).
        insertDocument: *const fn (ptr: *anyopaque, doc: types.Document) anyerror!void,
        /// Coarse candidate retrieval; the engine ranks the results.
        /// All returned strings are owned by `alloc` (the caller's arena).
        search: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, q: types.SearchQuery) anyerror![]types.Document,
        countDocuments: *const fn (ptr: *anyopaque) usize,
        /// Per-source document counts. Strings owned by `alloc`.
        countBySource: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator) anyerror![]types.SourceCount,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn insertDocument(self: Repository, doc: types.Document) !void {
        return self.vtable.insertDocument(self.ptr, doc);
    }

    pub fn search(self: Repository, alloc: std.mem.Allocator, q: types.SearchQuery) ![]types.Document {
        return self.vtable.search(self.ptr, alloc, q);
    }

    pub fn countDocuments(self: Repository) usize {
        return self.vtable.countDocuments(self.ptr);
    }

    pub fn countBySource(self: Repository, alloc: std.mem.Allocator) ![]types.SourceCount {
        return self.vtable.countBySource(self.ptr, alloc);
    }

    pub fn deinit(self: Repository) void {
        self.vtable.deinit(self.ptr);
    }
};
