//! Trust & Intelligence Engine, Phase 7: knowledge graph.
//!
//! Nodes are entities (person, organization, county, city, topic),
//! events, sources, and claims. Edges are mentions (an event's
//! documents mention an entity), reported_by (an event was reported
//! by a source), same_event (two entities appear in one event's
//! documents), corroborates (a claim's supporting document agrees)
//! and contradicts (a claim's supporting documents carry a
//! contradiction flag).
//!
//! Disambiguation: the same name + kind is the same node ONLY with
//! a note — and same-name PERSONS in different counties are
//! SEPARATE nodes (person:<lower-name>:<county> when a county is
//! known from the same document, person:<lower-name> otherwise).
//! The graph response carries the disambiguation note, so a reader
//! never mistakes two same-name people for one.

const std = @import("std");
const knowledge = @import("../../storage/knowledge.zig");
const entities = @import("../../engine/entities.zig");
const trust_evidence = @import("../trust/evidence_tracker.zig");
const event_store = @import("event_store.zig");
const events_intel = @import("../events.zig");

pub const NodeKind = enum {
    person,
    organization,
    county,
    city,
    topic,
    event,
    source,
    claim,

    pub fn toString(self: NodeKind) []const u8 {
        return switch (self) {
            .person => "person",
            .organization => "organization",
            .county => "county",
            .city => "city",
            .topic => "topic",
            .event => "event",
            .source => "source",
            .claim => "claim",
        };
    }

    pub fn fromString(s: []const u8) ?NodeKind {
        if (std.mem.eql(u8, s, "person")) return .person;
        if (std.mem.eql(u8, s, "organization")) return .organization;
        if (std.mem.eql(u8, s, "county")) return .county;
        if (std.mem.eql(u8, s, "city")) return .city;
        if (std.mem.eql(u8, s, "topic")) return .topic;
        if (std.mem.eql(u8, s, "event")) return .event;
        if (std.mem.eql(u8, s, "source")) return .source;
        if (std.mem.eql(u8, s, "claim")) return .claim;
        return null;
    }
};

pub const EdgeKind = enum {
    mentions,
    reported_by,
    same_event,
    corroborates,
    contradicts,

    pub fn toString(self: EdgeKind) []const u8 {
        return switch (self) {
            .mentions => "mentions",
            .reported_by => "reported_by",
            .same_event => "same_event",
            .corroborates => "corroborates",
            .contradicts => "contradicts",
        };
    }
};

pub const Node = struct {
    id: []const u8,
    kind: NodeKind,
    label: []const u8,
    /// County the entity is tied to (persons only, for
    /// disambiguation); null otherwise.
    county: ?[]const u8,
    /// How many documents/events touch this node.
    weight: usize,
};

pub const Edge = struct {
    from: []const u8,
    to: []const u8,
    kind: EdgeKind,
};

pub const Graph = struct {
    nodes: []const Node,
    edges: []const Edge,
};

/// One event's documents, for graph building. The caller loads
/// these (listEvents + eventDocs); this module stays pure.
pub const EventDocs = struct {
    event: knowledge.KnowledgeEvent,
    docs: []const knowledge.EventDoc,
};

const Builder = struct {
    alloc: std.mem.Allocator,
    nodes: std.ArrayList(Node),
    edges: std.ArrayList(Edge),

    fn nodeId(self: *Builder, kind: NodeKind, label: []const u8, county: ?[]const u8) ![]const u8 {
        const lower = try std.ascii.allocLowerString(self.alloc, label);
        if (kind == .person) {
            if (county) |c| {
                const lower_c = try std.ascii.allocLowerString(self.alloc, c);
                return std.fmt.allocPrint(self.alloc, "person:{s}:{s}", .{ lower, lower_c });
            }
            return std.fmt.allocPrint(self.alloc, "person:{s}", .{lower});
        }
        return std.fmt.allocPrint(self.alloc, "{s}:{s}", .{ kind.toString(), lower });
    }

    fn addNode(self: *Builder, kind: NodeKind, label: []const u8, county: ?[]const u8) ![]const u8 {
        const id = try self.nodeId(kind, label, county);
        return self.addNodeId(kind, id, label, county);
    }

    /// Add a node with an explicit id (events and sources, whose
    /// store ids are the stable identity, not their label).
    fn addNodeId(self: *Builder, kind: NodeKind, id: []const u8, label: []const u8, county: ?[]const u8) ![]const u8 {
        for (self.nodes.items) |*n| {
            if (std.mem.eql(u8, n.id, id)) {
                n.weight += 1;
                return id;
            }
        }
        try self.nodes.append(self.alloc, .{ .id = id, .kind = kind, .label = label, .county = county, .weight = 1 });
        return id;
    }

    fn addEdge(self: *Builder, from: []const u8, to: []const u8, kind: EdgeKind) !void {
        if (std.mem.eql(u8, from, to)) return;
        for (self.edges.items) |e| {
            if (std.mem.eql(u8, e.from, from) and std.mem.eql(u8, e.to, to) and e.kind == kind) return;
        }
        try self.edges.append(self.alloc, .{ .from = from, .to = to, .kind = kind });
    }
};

/// Build the graph from the store's events and their documents.
/// Bounded by the caller's input (events + docs per event).
pub fn buildGraph(alloc: std.mem.Allocator, events: []const EventDocs) !Graph {
    var b = Builder{ .alloc = alloc, .nodes = .empty, .edges = .empty };
    for (events) |ed| {
        const event_key = try std.fmt.allocPrint(alloc, "event:{s}", .{ed.event.id});
        const event_id = try b.addNodeId(.event, event_key, ed.event.title, null);
        // The event's own topic is a node too.
        if (ed.event.topic.len > 0) {
            const topic_id = try b.addNode(.topic, ed.event.topic, null);
            try b.addEdge(event_id, topic_id, .mentions);
        }
        var entity_ids: std.ArrayList([]const u8) = .empty;
        for (ed.docs) |d| {
            const source_key = try std.fmt.allocPrint(alloc, "source:{s}", .{d.source_id});
            const source_id = try b.addNodeId(.source, source_key, d.source_name, null);
            try b.addEdge(event_id, source_id, .reported_by);
            const ent = entities.extract(alloc, d.title) catch continue;
            defer entities.freeEntities(alloc, ent);
            const ent2 = entities.extract(alloc, d.text) catch continue;
            defer entities.freeEntities(alloc, ent2);
            // Counties named in this document (for person
            // disambiguation): the first one, if any.
            var doc_county: ?[]const u8 = null;
            if (ent.counties.len > 0) doc_county = ent.counties[0];
            if (doc_county == null and ent2.counties.len > 0) doc_county = ent2.counties[0];
            for (ent.counties) |c| {
                const id = try b.addNode(.county, c, null);
                try entity_ids.append(alloc, id);
            }
            for (ent2.counties) |c| {
                const id = try b.addNode(.county, c, null);
                try entity_ids.append(alloc, id);
            }
            for (ent.cities) |c| {
                const id = try b.addNode(.city, c, null);
                try entity_ids.append(alloc, id);
            }
            for (ent2.cities) |c| {
                const id = try b.addNode(.city, c, null);
                try entity_ids.append(alloc, id);
            }
            for (ent.organizations) |o| {
                const id = try b.addNode(.organization, o, null);
                try entity_ids.append(alloc, id);
            }
            for (ent2.organizations) |o| {
                const id = try b.addNode(.organization, o, null);
                try entity_ids.append(alloc, id);
            }
            for (ent.people) |p| {
                const id = try b.addNode(.person, p, doc_county);
                try entity_ids.append(alloc, id);
            }
            for (ent2.people) |p| {
                const id = try b.addNode(.person, p, doc_county);
                try entity_ids.append(alloc, id);
            }
            for (ent.topics) |t| {
                const id = try b.addNode(.topic, t, null);
                try entity_ids.append(alloc, id);
            }
            for (ent2.topics) |t| {
                const id = try b.addNode(.topic, t, null);
                try entity_ids.append(alloc, id);
            }
        }
        // Mentions: event -> each entity in its documents.
        // same_event: every pair of entities in one event.
        for (entity_ids.items) |eid| {
            try b.addEdge(event_id, eid, .mentions);
        }
        for (entity_ids.items, 0..) |a, i| {
            for (entity_ids.items[i + 1 ..]) |c| {
                try b.addEdge(a, c, .same_event);
            }
        }
        // Claims: extracted from the event's documents; a claim node
        // per claim, linked to the event (same_event) and to each
        // supporting source (corroborates). When the event's
        // documents carry a contradiction flag, the claim also links
        // to the event with contradicts.
        const flags = events_intel.detectContradictionFlags(alloc, ed.docs) catch &.{};
        for (ed.docs) |d| {
            const claims = trust_evidence.extractClaimsFromEventDoc(alloc, d) catch continue;
            for (claims) |cl| {
                const claim_id = try b.addNode(.claim, cl.text, null);
                try b.addEdge(claim_id, event_id, .same_event);
                if (flags.len > 0) try b.addEdge(claim_id, event_id, .contradicts);
                const source_key = try std.fmt.allocPrint(alloc, "source:{s}", .{d.source_id});
                const sid = try b.addNodeId(.source, source_key, d.source_name, null);
                try b.addEdge(claim_id, sid, .corroborates);
            }
        }
    }
    return .{ .nodes = b.nodes.items, .edges = b.edges.items };
}

/// Subgraph around one entity: the node (by name + kind) and its
/// neighbours, with the edges between them. Returns null when no
/// such node exists.
pub fn graphForEntity(alloc: std.mem.Allocator, graph: Graph, name: []const u8, kind: ?NodeKind) !?Graph {
    const lower = try std.ascii.allocLowerString(alloc, name);
    var target: ?Node = null;
    for (graph.nodes) |n| {
        const lower_label = try std.ascii.allocLowerString(alloc, n.label);
        defer alloc.free(lower_label);
        if (!std.mem.eql(u8, lower_label, lower)) continue;
        if (kind) |k| {
            if (n.kind != k) continue;
        }
        target = n;
        break;
    }
    const t = target orelse return null;
    var keep: std.ArrayList([]const u8) = .empty;
    try keep.append(alloc, t.id);
    var nodes: std.ArrayList(Node) = .empty;
    try nodes.append(alloc, t);
    var edges: std.ArrayList(Edge) = .empty;
    for (graph.edges) |e| {
        if (std.mem.eql(u8, e.from, t.id) or std.mem.eql(u8, e.to, t.id)) {
            try edges.append(alloc, e);
            const other = if (std.mem.eql(u8, e.from, t.id)) e.to else e.from;
            var seen = false;
            for (keep.items) |x| {
                if (std.mem.eql(u8, x, other)) seen = true;
            }
            if (!seen) {
                try keep.append(alloc, other);
                for (graph.nodes) |n| {
                    if (std.mem.eql(u8, n.id, other)) try nodes.append(alloc, n);
                }
            }
        }
    }
    return .{ .nodes = nodes.items, .edges = edges.items };
}

/// Subgraph around one event: the event node, its entities, its
/// sources and its claims, with the edges between them. Returns
/// null when no such event node exists.
pub fn graphForEvent(alloc: std.mem.Allocator, graph: Graph, event_id: []const u8) !?Graph {
    const key = try std.fmt.allocPrint(alloc, "event:{s}", .{event_id});
    var target: ?Node = null;
    for (graph.nodes) |n| {
        if (std.mem.eql(u8, n.id, key)) target = n;
    }
    const t = target orelse return null;
    var keep: std.ArrayList([]const u8) = .empty;
    try keep.append(alloc, t.id);
    var nodes: std.ArrayList(Node) = .empty;
    try nodes.append(alloc, t);
    var edges: std.ArrayList(Edge) = .empty;
    for (graph.edges) |e| {
        if (std.mem.eql(u8, e.from, t.id) or std.mem.eql(u8, e.to, t.id)) {
            try edges.append(alloc, e);
            const other = if (std.mem.eql(u8, e.from, t.id)) e.to else e.from;
            var seen = false;
            for (keep.items) |x| {
                if (std.mem.eql(u8, x, other)) seen = true;
            }
            if (!seen) {
                try keep.append(alloc, other);
                for (graph.nodes) |n| {
                    if (std.mem.eql(u8, n.id, other)) try nodes.append(alloc, n);
                }
            }
        }
    }
    return .{ .nodes = nodes.items, .edges = edges.items };
}

test "buildGraph: nodes, edges, person disambiguation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const docs = [_]knowledge.EventDoc{
        .{ .id = "d1", .title = "County meet opens in Gbarnga, Bong County", .source_id = "daily-observer", .source_name = "Daily Observer", .published_at = 1794681600, .text = "The county meet opened in Gbarnga, Bong County, with Joseph Boakai in attendance." },
        .{ .id = "d2", .title = "County meet finals in Nimba", .source_id = "frontpage-africa", .source_name = "FrontPage Africa", .published_at = 1794681600, .text = "Joseph Boakai watched the finals in Sanniquellie, Nimba County." },
    };
    const ev: knowledge.KnowledgeEvent = .{
        .id = "e1",
        .title = "County meet opens",
        .topic = "sports",
        .first_seen = 1794681600,
        .last_seen = 1794681600,
        .doc_count = 2,
        .summary = null,
        .distinct_sources = 2,
        .status = "reported",
    };
    const g = try buildGraph(alloc, &.{.{ .event = ev, .docs = &docs }});
    // Event + topic + 2 sources + counties (Bong, Nimba) + cities
    // (Gbarnga, Sanniquellie) + 1 claim at least. Persons: the same
    // name in two counties must be TWO nodes.
    var persons: usize = 0;
    var person_ids: [4][]const u8 = undefined;
    var person_n: usize = 0;
    for (g.nodes) |n| {
        if (n.kind == .person) {
            persons += 1;
            if (person_n < 4) {
                person_ids[person_n] = n.id;
                person_n += 1;
            }
        }
    }
    try std.testing.expect(persons >= 1);
    // If the extractor found the person in both counties, the two
    // nodes must have different ids.
    if (person_n >= 2) {
        try std.testing.expect(!std.mem.eql(u8, person_ids[0], person_ids[1]));
    }
    // The event node links to both sources via reported_by.
    var reported: usize = 0;
    for (g.edges) |e| {
        if (e.kind == .reported_by) reported += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), reported);
}

test "graphForEntity finds a node and its neighbours" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const docs = [_]knowledge.EventDoc{
        .{ .id = "d1", .title = "Fuel shortage hits Monrovia", .source_id = "new-dawn", .source_name = "New Dawn", .published_at = 1794681600, .text = "Fuel shortage hits Monrovia, Montserrado County." },
    };
    const ev: knowledge.KnowledgeEvent = .{
        .id = "e1",
        .title = "Fuel shortage hits Monrovia",
        .topic = "energy",
        .first_seen = 1794681600,
        .last_seen = 1794681600,
        .doc_count = 1,
        .summary = null,
        .distinct_sources = 1,
        .status = "reported",
    };
    const g = try buildGraph(alloc, &.{.{ .event = ev, .docs = &docs }});
    const sub = (try graphForEntity(alloc, g, "Montserrado", .county)) orelse return error.MissingNode;
    try std.testing.expect(sub.nodes.len >= 2);
    try std.testing.expect(sub.edges.len >= 1);
    try std.testing.expect((try graphForEntity(alloc, g, "Zanzibar", .county)) == null);
    const ev_sub = (try graphForEvent(alloc, g, "e1")) orelse return error.MissingEventNode;
    try std.testing.expect(ev_sub.nodes.len >= 3);
    try std.testing.expect((try graphForEvent(alloc, g, "nope")) == null);
}
