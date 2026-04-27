// JeffJSIndexedDBBridge.swift
// JeffJS IndexedDB Bridge — Registers __nativeIDBBridge on a JeffJS context.
//
// Port of JSIndexedDBBridge (JavaScriptCore-based) to the JeffJS native function API.
// Uses the same SQLite3-backed persistent storage; only the JS<->Swift boundary changes.
//
// All methods are registered on a single `__nativeIDBBridge` object on the JeffJS
// global, matching the JSC path so the same `indexedDBBridgeGlue` JS shim works
// with both engines.

import Foundation
import SQLite3

// MARK: - JeffJSIndexedDBBridge

/// Native IndexedDB bridge for JeffJS, backed by SQLite3.
///
/// Usage:
/// ```swift
/// let bridge = JeffJSIndexedDBBridge(scope: "example.com")
/// bridge.register(on: ctx)
/// ```
@MainActor
final class JeffJSIndexedDBBridge {

    private var db: OpaquePointer?
    private let dbPath: String

    init(scope: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = dir.appendingPathComponent("ReactNatively", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        dbPath = folder.appendingPathComponent("indexeddb_\(scope).sqlite3").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            db = nil
        }
        createSchema()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Schema

    private func createSchema() {
        guard let db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS idb_databases (
            name TEXT PRIMARY KEY,
            version INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS idb_stores (
            db_name TEXT NOT NULL,
            store_name TEXT NOT NULL,
            key_path TEXT,
            auto_increment INTEGER NOT NULL DEFAULT 0,
            auto_key INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (db_name, store_name)
        );
        CREATE TABLE IF NOT EXISTS idb_indexes (
            db_name TEXT NOT NULL,
            store_name TEXT NOT NULL,
            index_name TEXT NOT NULL,
            key_path TEXT NOT NULL,
            is_unique INTEGER NOT NULL DEFAULT 0,
            is_multi_entry INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (db_name, store_name, index_name)
        );
        CREATE TABLE IF NOT EXISTS idb_data (
            db_name TEXT NOT NULL,
            store_name TEXT NOT NULL,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (db_name, store_name, key)
        );
        CREATE INDEX IF NOT EXISTS idx_idb_data_store ON idb_data(db_name, store_name);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Registration

    /// Registers `__nativeIDBBridge` on the JeffJS global object with all IndexedDB methods.
    func register(on ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        let bridge = ctx.newObject()

        // -- Database operations --

        // getDatabaseVersion(name) -> {exists: Bool, version: Int}
        ctx.setPropertyFunc(obj: bridge, name: "getDatabaseVersion", fn: { [weak self] ctx, thisVal, args in
            guard let self, let name = self.str(ctx, args, 0) else {
                return self?.makeResult(ctx, ["exists": false, "version": 0]) ?? JeffJSValue.undefined
            }
            return self.makeResult(ctx, self.getDatabaseVersion(name))
        }, length: 1)

        // createDatabase(name, version)
        ctx.setPropertyFunc(obj: bridge, name: "createDatabase", fn: { [weak self] ctx, thisVal, args in
            guard let self, let name = self.str(ctx, args, 0) else { return JeffJSValue.undefined }
            let version = self.int(ctx, args, 1) ?? 1
            self.createDatabase(name, version: version)
            return JeffJSValue.undefined
        }, length: 2)

        // setDatabaseVersion(name, version)
        ctx.setPropertyFunc(obj: bridge, name: "setDatabaseVersion", fn: { [weak self] ctx, thisVal, args in
            guard let self, let name = self.str(ctx, args, 0) else { return JeffJSValue.undefined }
            let version = self.int(ctx, args, 1) ?? 1
            self.setDatabaseVersion(name, version: version)
            return JeffJSValue.undefined
        }, length: 2)

        // deleteDatabase(name)
        ctx.setPropertyFunc(obj: bridge, name: "deleteDatabase", fn: { [weak self] ctx, thisVal, args in
            guard let self, let name = self.str(ctx, args, 0) else { return JeffJSValue.undefined }
            self.deleteDatabase(name)
            return JeffJSValue.undefined
        }, length: 1)

        // listDatabases() -> [{name, version}]
        ctx.setPropertyFunc(obj: bridge, name: "listDatabases", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return ctx.newArray() }
            let dbs = self.listDatabases()
            let arr = ctx.newArray()
            for (i, entry) in dbs.enumerated() {
                let obj = self.makeResult(ctx, entry)
                _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: obj)
            }
            self.setArrayLength(ctx, arr, dbs.count)
            return arr
        }, length: 0)

        // -- Object store operations --

        // createObjectStore(dbName, storeName, keyPath, autoIncrement)
        ctx.setPropertyFunc(obj: bridge, name: "createObjectStore", fn: { [weak self] ctx, thisVal, args in
            guard let self, let dbName = self.str(ctx, args, 0), let storeName = self.str(ctx, args, 1) else {
                return JeffJSValue.undefined
            }
            let keyPath = self.str(ctx, args, 2)
            let autoIncrement = self.bool(ctx, args, 3) ?? false
            let kp = (keyPath?.isEmpty ?? true) ? nil : keyPath
            self.createObjectStore(dbName: dbName, storeName: storeName, keyPath: kp, autoIncrement: autoIncrement)
            return JeffJSValue.undefined
        }, length: 4)

        // deleteObjectStore(dbName, storeName)
        ctx.setPropertyFunc(obj: bridge, name: "deleteObjectStore", fn: { [weak self] ctx, thisVal, args in
            guard let self, let dbName = self.str(ctx, args, 0), let storeName = self.str(ctx, args, 1) else {
                return JeffJSValue.undefined
            }
            self.deleteObjectStore(dbName: dbName, storeName: storeName)
            return JeffJSValue.undefined
        }, length: 2)

        // getObjectStoreNames(dbName) -> [String]
        ctx.setPropertyFunc(obj: bridge, name: "getObjectStoreNames", fn: { [weak self] ctx, thisVal, args in
            guard let self, let dbName = self.str(ctx, args, 0) else { return ctx.newArray() }
            let names = self.getObjectStoreNames(dbName: dbName)
            return self.makeStringArray(ctx, names)
        }, length: 1)

        // getObjectStoreInfo(dbName, storeName) -> {keyPath, autoIncrement}
        ctx.setPropertyFunc(obj: bridge, name: "getObjectStoreInfo", fn: { [weak self] ctx, thisVal, args in
            guard let self, let dbName = self.str(ctx, args, 0), let storeName = self.str(ctx, args, 1) else {
                return ctx.newObject()
            }
            return self.makeResult(ctx, self.getObjectStoreInfo(dbName: dbName, storeName: storeName))
        }, length: 2)

        // -- Data operations --

        // put(dbName, storeName, keyJSON, valueJSON) -> keyJSON
        ctx.setPropertyFunc(obj: bridge, name: "put", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let key = self.str(ctx, args, 2),
                  let value = self.str(ctx, args, 3) else {
                return ctx.newStringValue("")
            }
            let result = self.putRecord(dbName: dbName, storeName: storeName, keyJSON: key, valueJSON: value)
            return ctx.newStringValue(result)
        }, length: 4)

        // add(dbName, storeName, keyJSON, valueJSON) -> keyJSON or ""
        ctx.setPropertyFunc(obj: bridge, name: "add", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let key = self.str(ctx, args, 2),
                  let value = self.str(ctx, args, 3) else {
                return ctx.newStringValue("")
            }
            let result = self.addRecord(dbName: dbName, storeName: storeName, keyJSON: key, valueJSON: value)
            return ctx.newStringValue(result)
        }, length: 4)

        // get(dbName, storeName, keyJSON) -> valueJSON or ""
        ctx.setPropertyFunc(obj: bridge, name: "get", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let key = self.str(ctx, args, 2) else {
                return ctx.newStringValue("")
            }
            let result = self.getRecord(dbName: dbName, storeName: storeName, keyJSON: key)
            return ctx.newStringValue(result)
        }, length: 3)

        // getAll(dbName, storeName, rangeJSON, count) -> JSON array
        ctx.setPropertyFunc(obj: bridge, name: "getAll", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1) else {
                return ctx.newStringValue("[]")
            }
            let rangeJSON = self.str(ctx, args, 2) ?? ""
            let count = self.int(ctx, args, 3) ?? 0
            let result = self.getAllRecords(dbName: dbName, storeName: storeName, rangeJSON: rangeJSON, count: count)
            return ctx.newStringValue(result)
        }, length: 4)

        // getAllKeys(dbName, storeName, rangeJSON, count) -> JSON array of keys
        ctx.setPropertyFunc(obj: bridge, name: "getAllKeys", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1) else {
                return ctx.newStringValue("[]")
            }
            let rangeJSON = self.str(ctx, args, 2) ?? ""
            let count = self.int(ctx, args, 3) ?? 0
            let result = self.getAllKeys(dbName: dbName, storeName: storeName, rangeJSON: rangeJSON, count: count)
            return ctx.newStringValue(result)
        }, length: 4)

        // deleteRecord(dbName, storeName, keyJSON)
        ctx.setPropertyFunc(obj: bridge, name: "deleteRecord", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let key = self.str(ctx, args, 2) else {
                return JeffJSValue.undefined
            }
            self.deleteRecord(dbName: dbName, storeName: storeName, keyJSON: key)
            return JeffJSValue.undefined
        }, length: 3)

        // deleteRange(dbName, storeName, rangeJSON)
        ctx.setPropertyFunc(obj: bridge, name: "deleteRange", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let rangeJSON = self.str(ctx, args, 2) else {
                return JeffJSValue.undefined
            }
            self.deleteRange(dbName: dbName, storeName: storeName, rangeJSON: rangeJSON)
            return JeffJSValue.undefined
        }, length: 3)

        // clearStore(dbName, storeName)
        ctx.setPropertyFunc(obj: bridge, name: "clearStore", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1) else {
                return JeffJSValue.undefined
            }
            self.clearStore(dbName: dbName, storeName: storeName)
            return JeffJSValue.undefined
        }, length: 2)

        // countRecords(dbName, storeName, rangeJSON) -> Int
        ctx.setPropertyFunc(obj: bridge, name: "countRecords", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1) else {
                return JeffJSValue.newInt32(0)
            }
            let rangeJSON = self.str(ctx, args, 2) ?? ""
            let count = self.countRecords(dbName: dbName, storeName: storeName, rangeJSON: rangeJSON)
            return JeffJSValue.newInt32(Int32(count))
        }, length: 3)

        // -- Index operations --

        // createIndex(dbName, storeName, indexName, keyPath, unique, multiEntry)
        ctx.setPropertyFunc(obj: bridge, name: "createIndex", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let indexName = self.str(ctx, args, 2),
                  let keyPath = self.str(ctx, args, 3) else {
                return JeffJSValue.undefined
            }
            let unique = self.bool(ctx, args, 4) ?? false
            let multiEntry = self.bool(ctx, args, 5) ?? false
            self.createIndex(dbName: dbName, storeName: storeName, indexName: indexName, keyPath: keyPath, unique: unique, multiEntry: multiEntry)
            return JeffJSValue.undefined
        }, length: 6)

        // deleteIndex(dbName, storeName, indexName)
        ctx.setPropertyFunc(obj: bridge, name: "deleteIndex", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let indexName = self.str(ctx, args, 2) else {
                return JeffJSValue.undefined
            }
            self.deleteIndex(dbName: dbName, storeName: storeName, indexName: indexName)
            return JeffJSValue.undefined
        }, length: 3)

        // getIndexNames(dbName, storeName) -> [String]
        ctx.setPropertyFunc(obj: bridge, name: "getIndexNames", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1) else {
                return ctx.newArray()
            }
            let names = self.getIndexNames(dbName: dbName, storeName: storeName)
            return self.makeStringArray(ctx, names)
        }, length: 2)

        // getIndexInfo(dbName, storeName, indexName) -> {keyPath, unique, multiEntry}
        ctx.setPropertyFunc(obj: bridge, name: "getIndexInfo", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let indexName = self.str(ctx, args, 2) else {
                return ctx.newObject()
            }
            return self.makeResult(ctx, self.getIndexInfo(dbName: dbName, storeName: storeName, indexName: indexName))
        }, length: 3)

        // getByIndex(dbName, storeName, indexName, keyJSON) -> valueJSON
        ctx.setPropertyFunc(obj: bridge, name: "getByIndex", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let indexName = self.str(ctx, args, 2),
                  let keyJSON = self.str(ctx, args, 3) else {
                return ctx.newStringValue("")
            }
            let result = self.getByIndex(dbName: dbName, storeName: storeName, indexName: indexName, keyJSON: keyJSON)
            return ctx.newStringValue(result)
        }, length: 4)

        // getAllByIndex(dbName, storeName, indexName, rangeJSON, count) -> JSON array
        ctx.setPropertyFunc(obj: bridge, name: "getAllByIndex", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let indexName = self.str(ctx, args, 2) else {
                return ctx.newStringValue("[]")
            }
            let rangeJSON = self.str(ctx, args, 3) ?? ""
            let count = self.int(ctx, args, 4) ?? 0
            let result = self.getAllByIndex(dbName: dbName, storeName: storeName, indexName: indexName, rangeJSON: rangeJSON, count: count)
            return ctx.newStringValue(result)
        }, length: 5)

        // getKeyByIndex(dbName, storeName, indexName, keyJSON) -> keyJSON
        ctx.setPropertyFunc(obj: bridge, name: "getKeyByIndex", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let indexName = self.str(ctx, args, 2),
                  let keyJSON = self.str(ctx, args, 3) else {
                return ctx.newStringValue("")
            }
            let result = self.getKeyByIndex(dbName: dbName, storeName: storeName, indexName: indexName, keyJSON: keyJSON)
            return ctx.newStringValue(result)
        }, length: 4)

        // getAllKeysByIndex(dbName, storeName, indexName, rangeJSON, count) -> JSON array
        ctx.setPropertyFunc(obj: bridge, name: "getAllKeysByIndex", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let indexName = self.str(ctx, args, 2) else {
                return ctx.newStringValue("[]")
            }
            let rangeJSON = self.str(ctx, args, 3) ?? ""
            let count = self.int(ctx, args, 4) ?? 0
            let result = self.getAllKeysByIndex(dbName: dbName, storeName: storeName, indexName: indexName, rangeJSON: rangeJSON, count: count)
            return ctx.newStringValue(result)
        }, length: 5)

        // countByIndex(dbName, storeName, indexName, rangeJSON) -> Int
        ctx.setPropertyFunc(obj: bridge, name: "countByIndex", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let indexName = self.str(ctx, args, 2) else {
                return JeffJSValue.newInt32(0)
            }
            let rangeJSON = self.str(ctx, args, 3) ?? ""
            let count = self.countByIndex(dbName: dbName, storeName: storeName, indexName: indexName, rangeJSON: rangeJSON)
            return JeffJSValue.newInt32(Int32(count))
        }, length: 4)

        // getCursorRecords(dbName, storeName, rangeJSON, direction) -> JSON array
        ctx.setPropertyFunc(obj: bridge, name: "getCursorRecords", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1) else {
                return ctx.newStringValue("[]")
            }
            let rangeJSON = self.str(ctx, args, 2) ?? ""
            let direction = self.str(ctx, args, 3) ?? "next"
            let result = self.getCursorRecords(dbName: dbName, storeName: storeName, rangeJSON: rangeJSON, direction: direction)
            return ctx.newStringValue(result)
        }, length: 4)

        // getIndexCursorRecords(dbName, storeName, indexName, rangeJSON, direction) -> JSON array
        ctx.setPropertyFunc(obj: bridge, name: "getIndexCursorRecords", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1),
                  let indexName = self.str(ctx, args, 2) else {
                return ctx.newStringValue("[]")
            }
            let rangeJSON = self.str(ctx, args, 3) ?? ""
            let direction = self.str(ctx, args, 4) ?? "next"
            let result = self.getIndexCursorRecords(dbName: dbName, storeName: storeName, indexName: indexName, rangeJSON: rangeJSON, direction: direction)
            return ctx.newStringValue(result)
        }, length: 5)

        // nextAutoKey(dbName, storeName) -> Int
        ctx.setPropertyFunc(obj: bridge, name: "nextAutoKey", fn: { [weak self] ctx, thisVal, args in
            guard let self,
                  let dbName = self.str(ctx, args, 0),
                  let storeName = self.str(ctx, args, 1) else {
                return JeffJSValue.newInt32(1)
            }
            let key = self.nextAutoKey(dbName: dbName, storeName: storeName)
            return JeffJSValue.newInt32(Int32(key))
        }, length: 2)

        // Set bridge object on global
        ctx.setPropertyStr(obj: global, name: "__nativeIDBBridge", value: bridge)
    }

    // MARK: - Argument Extraction Helpers

    private func str(_ ctx: JeffJSContext, _ args: [JeffJSValue], _ index: Int) -> String? {
        guard index < args.count else { return nil }
        let val = args[index]
        if val.isUndefined || val.isNull { return nil }
        return ctx.toSwiftString(val)
    }

    private func int(_ ctx: JeffJSContext, _ args: [JeffJSValue], _ index: Int) -> Int? {
        guard index < args.count else { return nil }
        let val = args[index]
        if val.isUndefined || val.isNull { return nil }
        if let i = ctx.toInt32(val) { return Int(i) }
        return nil
    }

    private func bool(_ ctx: JeffJSContext, _ args: [JeffJSValue], _ index: Int) -> Bool? {
        guard index < args.count else { return nil }
        let val = args[index]
        if val.isUndefined || val.isNull { return nil }
        return ctx.toBool(val)
    }

    // MARK: - JeffJS Value Construction Helpers

    /// Converts a Swift `[String: Any]` dictionary to a JeffJS object.
    private func makeResult(_ ctx: JeffJSContext, _ dict: [String: Any]) -> JeffJSValue {
        let obj = ctx.newObject()
        for (key, value) in dict {
            let jsVal: JeffJSValue
            switch value {
            case let s as String:
                jsVal = ctx.newStringValue(s)
            case let b as Bool:
                jsVal = .newBool(b)
            case let i as Int:
                jsVal = .newInt32(Int32(i))
            case let n as NSNumber:
                // NSNumber could be bool or numeric — check objCType
                if String(cString: n.objCType) == "c" || String(cString: n.objCType) == "B" {
                    jsVal = .newBool(n.boolValue)
                } else {
                    jsVal = .newInt32(n.int32Value)
                }
            case is NSNull:
                jsVal = .null
            default:
                jsVal = .undefined
            }
            ctx.setPropertyStr(obj: obj, name: key, value: jsVal)
        }
        return obj
    }

    /// Creates a JeffJS array of strings.
    private func makeStringArray(_ ctx: JeffJSContext, _ strings: [String]) -> JeffJSValue {
        let arr = ctx.newArray()
        for (i, s) in strings.enumerated() {
            _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: ctx.newStringValue(s))
        }
        setArrayLength(ctx, arr, strings.count)
        return arr
    }

    /// Sets the `length` property on an array object using the context's native method.
    private func setArrayLength(_ ctx: JeffJSContext, _ arr: JeffJSValue, _ count: Int) {
        ctx.setArrayLength(arr, Int64(count))
    }

    // MARK: - Database Operations

    private func getDatabaseVersion(_ name: String) -> [String: Any] {
        guard let db else { return ["exists": false, "version": 0] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT version FROM idb_databases WHERE name = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let version = Int(sqlite3_column_int64(stmt, 0))
                return ["exists": true, "version": version]
            }
        }
        return ["exists": false, "version": 0]
    }

    private func createDatabase(_ name: String, version: Int) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO idb_databases (name, version) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, Int64(version))
            sqlite3_step(stmt)
        }
    }

    private func setDatabaseVersion(_ name: String, version: Int) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "UPDATE idb_databases SET version = ? WHERE name = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, Int64(version))
            sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
    }

    private func deleteDatabase(_ name: String) {
        guard let db else { return }
        let tables = ["idb_data", "idb_indexes", "idb_stores"]
        for table in tables {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE db_name = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "DELETE FROM idb_databases WHERE name = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
    }

    private func listDatabases() -> [[String: Any]] {
        guard let db else { return [] }
        var results: [[String: Any]] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT name, version FROM idb_databases", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 0))
                let version = Int(sqlite3_column_int64(stmt, 1))
                results.append(["name": name, "version": version])
            }
        }
        return results
    }

    // MARK: - Object Store Operations

    private func createObjectStore(dbName: String, storeName: String, keyPath: String?, autoIncrement: Bool) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO idb_stores (db_name, store_name, key_path, auto_increment, auto_key) VALUES (?, ?, ?, ?, 1)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
            if let keyPath {
                sqlite3_bind_text(stmt, 3, (keyPath as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_int(stmt, 4, autoIncrement ? 1 : 0)
            sqlite3_step(stmt)
        }
    }

    private func deleteObjectStore(dbName: String, storeName: String) {
        guard let db else { return }
        var stmt1: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM idb_data WHERE db_name = ? AND store_name = ?", -1, &stmt1, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt1, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt1, 2, (storeName as NSString).utf8String, -1, nil)
            sqlite3_step(stmt1)
        }
        sqlite3_finalize(stmt1)
        var stmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM idb_indexes WHERE db_name = ? AND store_name = ?", -1, &stmt2, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt2, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt2, 2, (storeName as NSString).utf8String, -1, nil)
            sqlite3_step(stmt2)
        }
        sqlite3_finalize(stmt2)
        var stmt3: OpaquePointer?
        defer { sqlite3_finalize(stmt3) }
        if sqlite3_prepare_v2(db, "DELETE FROM idb_stores WHERE db_name = ? AND store_name = ?", -1, &stmt3, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt3, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt3, 2, (storeName as NSString).utf8String, -1, nil)
            sqlite3_step(stmt3)
        }
    }

    private func getObjectStoreNames(dbName: String) -> [String] {
        guard let db else { return [] }
        var names: [String] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT store_name FROM idb_stores WHERE db_name = ? ORDER BY store_name", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                names.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        return names
    }

    private func getObjectStoreInfo(dbName: String, storeName: String) -> [String: Any] {
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT key_path, auto_increment FROM idb_stores WHERE db_name = ? AND store_name = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let keyPath: Any = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? NSNull() : String(cString: sqlite3_column_text(stmt, 0))
                let autoIncrement = sqlite3_column_int(stmt, 1) != 0
                return ["keyPath": keyPath, "autoIncrement": autoIncrement]
            }
        }
        return [:]
    }

    // MARK: - Data Operations

    private func putRecord(dbName: String, storeName: String, keyJSON: String, valueJSON: String) -> String {
        guard let db else { return "" }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO idb_data (db_name, store_name, key, value) VALUES (?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (keyJSON as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (valueJSON as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        return keyJSON
    }

    private func addRecord(dbName: String, storeName: String, keyJSON: String, valueJSON: String) -> String {
        guard let db else { return "" }
        var check: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT 1 FROM idb_data WHERE db_name = ? AND store_name = ? AND key = ?", -1, &check, nil) == SQLITE_OK {
            sqlite3_bind_text(check, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(check, 2, (storeName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(check, 3, (keyJSON as NSString).utf8String, -1, nil)
            if sqlite3_step(check) == SQLITE_ROW {
                sqlite3_finalize(check)
                return "" // Key exists — signal constraint error
            }
        }
        sqlite3_finalize(check)
        return putRecord(dbName: dbName, storeName: storeName, keyJSON: keyJSON, valueJSON: valueJSON)
    }

    private func getRecord(dbName: String, storeName: String, keyJSON: String) -> String {
        guard let db else { return "" }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT value FROM idb_data WHERE db_name = ? AND store_name = ? AND key = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (keyJSON as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                return String(cString: sqlite3_column_text(stmt, 0))
            }
        }
        return ""
    }

    private func getAllRecords(dbName: String, storeName: String, rangeJSON: String, count: Int) -> String {
        let rows = queryDataRows(dbName: dbName, storeName: storeName, rangeJSON: rangeJSON, count: count, valuesOnly: true)
        return "[\(rows.joined(separator: ","))]"
    }

    private func getAllKeys(dbName: String, storeName: String, rangeJSON: String, count: Int) -> String {
        let keys = queryDataKeys(dbName: dbName, storeName: storeName, rangeJSON: rangeJSON, count: count)
        return "[\(keys.joined(separator: ","))]"
    }

    private func deleteRecord(dbName: String, storeName: String, keyJSON: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "DELETE FROM idb_data WHERE db_name = ? AND store_name = ? AND key = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (keyJSON as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
    }

    private func deleteRange(dbName: String, storeName: String, rangeJSON: String) {
        guard let db else { return }
        let range = parseRange(rangeJSON)
        if let lower = range.lower, let upper = range.upper {
            let sql: String
            if range.lowerOpen && range.upperOpen {
                sql = "DELETE FROM idb_data WHERE db_name = ? AND store_name = ? AND key > ? AND key < ?"
            } else if range.lowerOpen {
                sql = "DELETE FROM idb_data WHERE db_name = ? AND store_name = ? AND key > ? AND key <= ?"
            } else if range.upperOpen {
                sql = "DELETE FROM idb_data WHERE db_name = ? AND store_name = ? AND key >= ? AND key < ?"
            } else {
                sql = "DELETE FROM idb_data WHERE db_name = ? AND store_name = ? AND key >= ? AND key <= ?"
            }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (lower as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (upper as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
        } else if let lower = range.lower {
            let sql = range.lowerOpen
                ? "DELETE FROM idb_data WHERE db_name = ? AND store_name = ? AND key > ?"
                : "DELETE FROM idb_data WHERE db_name = ? AND store_name = ? AND key >= ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (lower as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
        } else if let upper = range.upper {
            let sql = range.upperOpen
                ? "DELETE FROM idb_data WHERE db_name = ? AND store_name = ? AND key < ?"
                : "DELETE FROM idb_data WHERE db_name = ? AND store_name = ? AND key <= ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (upper as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
        }
    }

    private func clearStore(dbName: String, storeName: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "DELETE FROM idb_data WHERE db_name = ? AND store_name = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        // Reset auto key
        var stmt2: OpaquePointer?
        defer { sqlite3_finalize(stmt2) }
        if sqlite3_prepare_v2(db, "UPDATE idb_stores SET auto_key = 1 WHERE db_name = ? AND store_name = ?", -1, &stmt2, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt2, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt2, 2, (storeName as NSString).utf8String, -1, nil)
            sqlite3_step(stmt2)
        }
    }

    private func countRecords(dbName: String, storeName: String, rangeJSON: String) -> Int {
        guard let db else { return 0 }
        if rangeJSON.isEmpty {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM idb_data WHERE db_name = ? AND store_name = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    return Int(sqlite3_column_int64(stmt, 0))
                }
            }
            return 0
        }
        let keys = queryDataKeys(dbName: dbName, storeName: storeName, rangeJSON: rangeJSON, count: 0)
        return keys.count
    }

    // MARK: - Index Operations

    private func createIndex(dbName: String, storeName: String, indexName: String, keyPath: String, unique: Bool, multiEntry: Bool) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO idb_indexes (db_name, store_name, index_name, key_path, is_unique, is_multi_entry) VALUES (?, ?, ?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (indexName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (keyPath as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 5, unique ? 1 : 0)
            sqlite3_bind_int(stmt, 6, multiEntry ? 1 : 0)
            sqlite3_step(stmt)
        }
    }

    private func deleteIndex(dbName: String, storeName: String, indexName: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "DELETE FROM idb_indexes WHERE db_name = ? AND store_name = ? AND index_name = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (indexName as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
    }

    private func getIndexNames(dbName: String, storeName: String) -> [String] {
        guard let db else { return [] }
        var names: [String] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT index_name FROM idb_indexes WHERE db_name = ? AND store_name = ? ORDER BY index_name", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                names.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        return names
    }

    private func getIndexInfo(dbName: String, storeName: String, indexName: String) -> [String: Any] {
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT key_path, is_unique, is_multi_entry FROM idb_indexes WHERE db_name = ? AND store_name = ? AND index_name = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (indexName as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let keyPath = String(cString: sqlite3_column_text(stmt, 0))
                let unique = sqlite3_column_int(stmt, 1) != 0
                let multiEntry = sqlite3_column_int(stmt, 2) != 0
                return ["keyPath": keyPath, "unique": unique, "multiEntry": multiEntry]
            }
        }
        return [:]
    }

    private func getByIndex(dbName: String, storeName: String, indexName: String, keyJSON: String) -> String {
        let info = getIndexInfo(dbName: dbName, storeName: storeName, indexName: indexName)
        guard let keyPath = info["keyPath"] as? String else { return "" }
        let allRecords = queryAllDataRows(dbName: dbName, storeName: storeName)
        for (_, valueJSON) in allRecords {
            if let val = parseJSON(valueJSON), extractKeyJSON(from: val, keyPath: keyPath) == keyJSON {
                return valueJSON
            }
        }
        return ""
    }

    private func getAllByIndex(dbName: String, storeName: String, indexName: String, rangeJSON: String, count: Int) -> String {
        let info = getIndexInfo(dbName: dbName, storeName: storeName, indexName: indexName)
        guard let keyPath = info["keyPath"] as? String else { return "[]" }
        let range = parseRange(rangeJSON)
        let allRecords = queryAllDataRows(dbName: dbName, storeName: storeName)
        var results: [String] = []
        for (_, valueJSON) in allRecords {
            if let val = parseJSON(valueJSON) {
                let ik = extractKeyJSON(from: val, keyPath: keyPath)
                if keyInRange(ik, range: range) {
                    results.append(valueJSON)
                    if count > 0 && results.count >= count { break }
                }
            }
        }
        return "[\(results.joined(separator: ","))]"
    }

    private func getKeyByIndex(dbName: String, storeName: String, indexName: String, keyJSON: String) -> String {
        let info = getIndexInfo(dbName: dbName, storeName: storeName, indexName: indexName)
        guard let keyPath = info["keyPath"] as? String else { return "" }
        let allRecords = queryAllDataRows(dbName: dbName, storeName: storeName)
        for (primaryKey, valueJSON) in allRecords {
            if let val = parseJSON(valueJSON), extractKeyJSON(from: val, keyPath: keyPath) == keyJSON {
                return primaryKey
            }
        }
        return ""
    }

    private func getAllKeysByIndex(dbName: String, storeName: String, indexName: String, rangeJSON: String, count: Int) -> String {
        let info = getIndexInfo(dbName: dbName, storeName: storeName, indexName: indexName)
        guard let keyPath = info["keyPath"] as? String else { return "[]" }
        let range = parseRange(rangeJSON)
        let allRecords = queryAllDataRows(dbName: dbName, storeName: storeName)
        var keys: [String] = []
        for (primaryKey, valueJSON) in allRecords {
            if let val = parseJSON(valueJSON) {
                let ik = extractKeyJSON(from: val, keyPath: keyPath)
                if keyInRange(ik, range: range) {
                    keys.append(primaryKey)
                    if count > 0 && keys.count >= count { break }
                }
            }
        }
        return "[\(keys.joined(separator: ","))]"
    }

    private func countByIndex(dbName: String, storeName: String, indexName: String, rangeJSON: String) -> Int {
        let info = getIndexInfo(dbName: dbName, storeName: storeName, indexName: indexName)
        guard let keyPath = info["keyPath"] as? String else { return 0 }
        if rangeJSON.isEmpty {
            let allRecords = queryAllDataRows(dbName: dbName, storeName: storeName)
            var n = 0
            for (_, valueJSON) in allRecords {
                if let val = parseJSON(valueJSON), extractKeyJSON(from: val, keyPath: keyPath) != "" { n += 1 }
            }
            return n
        }
        let range = parseRange(rangeJSON)
        let allRecords = queryAllDataRows(dbName: dbName, storeName: storeName)
        var n = 0
        for (_, valueJSON) in allRecords {
            if let val = parseJSON(valueJSON) {
                let ik = extractKeyJSON(from: val, keyPath: keyPath)
                if keyInRange(ik, range: range) { n += 1 }
            }
        }
        return n
    }

    // MARK: - Cursor Operations

    private func getCursorRecords(dbName: String, storeName: String, rangeJSON: String, direction: String) -> String {
        guard let db else { return "[]" }
        let order = (direction == "prev" || direction == "prevunique") ? "DESC" : "ASC"
        let range = parseRange(rangeJSON)
        var (sql, params) = buildRangeQuery(selectClause: "SELECT key, value", dbName: dbName, storeName: storeName, range: range)
        sql += " ORDER BY key \(order)"
        var results: [String] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for (i, p) in params.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), (p as NSString).utf8String, -1, nil)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(stmt, 0))
                let value = String(cString: sqlite3_column_text(stmt, 1))
                results.append("{\"key\":\(key),\"primaryKey\":\(key),\"value\":\(value)}")
            }
        }
        return "[\(results.joined(separator: ","))]"
    }

    private func getIndexCursorRecords(dbName: String, storeName: String, indexName: String, rangeJSON: String, direction: String) -> String {
        let info = getIndexInfo(dbName: dbName, storeName: storeName, indexName: indexName)
        guard let keyPath = info["keyPath"] as? String else { return "[]" }
        let range = parseRange(rangeJSON)
        let allRecords = queryAllDataRows(dbName: dbName, storeName: storeName)

        struct CursorRecord {
            let indexKey: String
            let primaryKey: String
            let value: String
        }

        var cursorRecords: [CursorRecord] = []
        for (pk, valueJSON) in allRecords {
            if let val = parseJSON(valueJSON) {
                let ik = extractKeyJSON(from: val, keyPath: keyPath)
                if !ik.isEmpty && keyInRange(ik, range: range) {
                    cursorRecords.append(CursorRecord(indexKey: ik, primaryKey: pk, value: valueJSON))
                }
            }
        }

        cursorRecords.sort { $0.indexKey < $1.indexKey }
        if direction == "prev" || direction == "prevunique" {
            cursorRecords.reverse()
        }

        let results = cursorRecords.map { r in
            "{\"key\":\(r.indexKey),\"primaryKey\":\(r.primaryKey),\"value\":\(r.value)}"
        }
        return "[\(results.joined(separator: ","))]"
    }

    // MARK: - Auto Key

    private func nextAutoKey(dbName: String, storeName: String) -> Int {
        guard let db else { return 1 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT auto_key FROM idb_stores WHERE db_name = ? AND store_name = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let key = Int(sqlite3_column_int64(stmt, 0))
                sqlite3_finalize(stmt)
                stmt = nil
                var update: OpaquePointer?
                if sqlite3_prepare_v2(db, "UPDATE idb_stores SET auto_key = ? WHERE db_name = ? AND store_name = ?", -1, &update, nil) == SQLITE_OK {
                    sqlite3_bind_int64(update, 1, Int64(key + 1))
                    sqlite3_bind_text(update, 2, (dbName as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(update, 3, (storeName as NSString).utf8String, -1, nil)
                    sqlite3_step(update)
                }
                sqlite3_finalize(update)
                return key
            }
        }
        return 1
    }

    // MARK: - Helpers

    private struct KeyRange {
        var lower: String?
        var upper: String?
        var lowerOpen: Bool = false
        var upperOpen: Bool = false
    }

    private func parseRange(_ json: String) -> KeyRange {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return KeyRange()
        }
        var range = KeyRange()
        if let l = obj["lower"] {
            if let s = l as? String { range.lower = "\"\(escapeJSON(s))\"" }
            else if let n = l as? NSNumber { range.lower = "\(n)" }
        }
        if let u = obj["upper"] {
            if let s = u as? String { range.upper = "\"\(escapeJSON(s))\"" }
            else if let n = u as? NSNumber { range.upper = "\(n)" }
        }
        range.lowerOpen = obj["lowerOpen"] as? Bool ?? false
        range.upperOpen = obj["upperOpen"] as? Bool ?? false
        return range
    }

    private func buildRangeQuery(selectClause: String, dbName: String, storeName: String, range: KeyRange) -> (String, [String]) {
        var sql = "\(selectClause) FROM idb_data WHERE db_name = ? AND store_name = ?"
        var params: [String] = [dbName, storeName]
        if let lower = range.lower {
            sql += range.lowerOpen ? " AND key > ?" : " AND key >= ?"
            params.append(lower)
        }
        if let upper = range.upper {
            sql += range.upperOpen ? " AND key < ?" : " AND key <= ?"
            params.append(upper)
        }
        return (sql, params)
    }

    private func queryDataRows(dbName: String, storeName: String, rangeJSON: String, count: Int, valuesOnly: Bool) -> [String] {
        guard let db else { return [] }
        let range = parseRange(rangeJSON)
        let select = valuesOnly ? "SELECT value" : "SELECT key, value"
        var (sql, params) = buildRangeQuery(selectClause: select, dbName: dbName, storeName: storeName, range: range)
        sql += " ORDER BY key ASC"
        if count > 0 { sql += " LIMIT \(count)" }
        var results: [String] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for (i, p) in params.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), (p as NSString).utf8String, -1, nil)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if valuesOnly {
                    results.append(String(cString: sqlite3_column_text(stmt, 0)))
                } else {
                    let key = String(cString: sqlite3_column_text(stmt, 0))
                    let value = String(cString: sqlite3_column_text(stmt, 1))
                    results.append("{\"key\":\(key),\"value\":\(value)}")
                }
            }
        }
        return results
    }

    private func queryDataKeys(dbName: String, storeName: String, rangeJSON: String, count: Int) -> [String] {
        guard let db else { return [] }
        let range = parseRange(rangeJSON)
        var (sql, params) = buildRangeQuery(selectClause: "SELECT key", dbName: dbName, storeName: storeName, range: range)
        sql += " ORDER BY key ASC"
        if count > 0 { sql += " LIMIT \(count)" }
        var keys: [String] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for (i, p) in params.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), (p as NSString).utf8String, -1, nil)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                keys.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        return keys
    }

    private func queryAllDataRows(dbName: String, storeName: String) -> [(String, String)] {
        guard let db else { return [] }
        var results: [(String, String)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "SELECT key, value FROM idb_data WHERE db_name = ? AND store_name = ? ORDER BY key ASC", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dbName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (storeName as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(stmt, 0))
                let value = String(cString: sqlite3_column_text(stmt, 1))
                results.append((key, value))
            }
        }
        return results
    }

    private func parseJSON(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func extractKeyJSON(from obj: [String: Any], keyPath: String) -> String {
        let parts = keyPath.split(separator: ".").map(String.init)
        var current: Any = obj
        for part in parts {
            guard let dict = current as? [String: Any], let next = dict[part] else { return "" }
            current = next
        }
        if let s = current as? String { return "\"\(escapeJSON(s))\"" }
        if let n = current as? NSNumber { return "\(n)" }
        return ""
    }

    private func keyInRange(_ keyJSON: String, range: KeyRange) -> Bool {
        if keyJSON.isEmpty { return false }
        if range.lower == nil && range.upper == nil { return true }
        if let lower = range.lower {
            let cmp = keyJSON.compare(lower)
            if cmp == .orderedAscending { return false }
            if cmp == .orderedSame && range.lowerOpen { return false }
        }
        if let upper = range.upper {
            let cmp = keyJSON.compare(upper)
            if cmp == .orderedDescending { return false }
            if cmp == .orderedSame && range.upperOpen { return false }
        }
        return true
    }

    private func escapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
}
