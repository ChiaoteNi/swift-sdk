import XCTest
import SwiftSyntaxMacrosTestSupport

@testable import MCPToolMacros

final class SchemaMacroTests: XCTestCase {
    
    func testSchemaMacroWithField() throws {
        assertMacroExpansion(
            """
            @Schema
            struct UserPreferences {
                @Field(description: "User's preferred theme", validOptions: ["light", "dark"])
                let theme: String
                
                @Field(description: "Enable notifications")
                let notifications: Bool
            }
            """,
            expandedSource: """
struct UserPreferences {
    let theme: String
    
    let notifications: Bool
}

extension UserPreferences: MCP.MCPParameterParsable {
    public static var inputSchema: MCP.Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                            "theme": .object(["type": .string("string"), "description": .string("User's preferred theme"), "enum": .array([.string("light"), .string("dark")])]),
                            "notifications": .object(["type": .string("boolean"), "description": .string("Enable notifications")])
            ]),
                    "required": .array([.string("theme"), .string("notifications")])
        ])
    }

    public static func parseArguments(_ args: [String: MCP.Value]) -> UserPreferences? {
        guard
            let parsedTheme = String(args["theme"] ?? .null),
                    let parsedNotifications = Bool(args["notifications"] ?? .null)
        else {
            return nil
        }

        return UserPreferences(theme: parsedTheme, notifications: parsedNotifications)
    }
}
""",
            macros: [
                "Schema": SchemaMacro.self,
                "Field": FieldMacro.self
            ]
        )
    }
    
    func testSchemaMacroWithOptionalField() throws {
        assertMacroExpansion(
            """
            @Schema
            struct UserProfile {
                @Field(description: "User name")
                let name: String
                
                @Field(description: "User email")
                let email: String?
            }
            """,
            expandedSource: """
struct UserProfile {
    let name: String
    
    let email: String?
}

extension UserProfile: MCP.MCPParameterParsable {
    public static var inputSchema: MCP.Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                            "name": .object(["type": .string("string"), "description": .string("User name")]),
                            "email": .object(["type": .string("string"), "description": .string("User email")])
            ]),
                    "required": .array([.string("name")])
        ])
    }

    public static func parseArguments(_ args: [String: MCP.Value]) -> UserProfile? {
        guard
            let parsedName = String(args["name"] ?? .null),
                    let parsedEmail = String(args["email"] ?? .null)
        else {
            return nil
        }

        return UserProfile(name: parsedName, email: parsedEmail)
    }
}
""",
            macros: [
                "Schema": SchemaMacro.self,
                "Field": FieldMacro.self
            ]
        )
    }

    func testSchemaMacroWithNestedSchema() throws {
        assertMacroExpansion(
            """
            @Schema
            struct Address {
                @Field(description: "Street")
                let street: String
            }

            @Schema
            struct User {
                @Field(description: "User address")
                let address: Address
            }
            """,
            expandedSource: """
struct Address {
    let street: String
}

extension Address: MCP.MCPParameterParsable {
    public static var inputSchema: MCP.Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                            "street": .object(["type": .string("string"), "description": .string("Street")])
            ]),
                    "required": .array([.string("street")])
        ])
    }

    public static func parseArguments(_ args: [String: MCP.Value]) -> Address? {
        guard
            let parsedStreet = String(args["street"] ?? .null)
        else {
            return nil
        }

        return Address(street: parsedStreet)
    }
}

struct User {
    let address: Address
}

extension User: MCP.MCPParameterParsable {
    public static var inputSchema: MCP.Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                            "address": Address.inputSchema
            ]),
                    "required": .array([.string("address")])
        ])
    }

    public static func parseArguments(_ args: [String: MCP.Value]) -> User? {
        guard
            let parsedAddress = Address.parseArguments(args["address"]?.objectValue ?? Dictionary<String, MCP.Value>())
        else {
            return nil
        }

        return User(address: parsedAddress)
    }
}
""",
            macros: [
                "Schema": SchemaMacro.self,
                "Field": FieldMacro.self
            ]
        )
    }
}