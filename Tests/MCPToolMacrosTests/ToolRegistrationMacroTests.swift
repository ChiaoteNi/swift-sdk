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
                @Field(description: "User's preferred theme", validOptions: ["light", "dark"])
                let theme: String
                
                @Field(description: "Enable notifications")
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
                        let theme = String(args["theme"] ?? .null),
                        let notifications = Bool(args["notifications"] ?? .null)
                    else { 
                        return nil 
                    }
                    
                    return UserPreferences(theme: theme, notifications: notifications)
                }
            }
            """,
            macros: [
                "Schema": SchemaMacro.self,
                "Field": FieldMacro.self
            ]
        )
    }
    
    func testInputSchemaMacro() throws {
        assertMacroExpansion(
            """
            @InputSchema
            struct UserInput {
                @SchemaField(description: "User name")
                let name: String
            }
            """,
            expandedSource: """
            struct UserInput {
                @SchemaField(description: "User name")
                let name: String
            }
            
            extension UserInput: MCP.MCPParameterParsable {
                public static var inputSchema: MCP.Value {
                    .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object(["type": .string("string"), "description": .string("User name")])
                        ]),
                        "required": .array([.string("name")])
                    ])
                }
                
                public static func parseArguments(_ args: [String: MCP.Value]) -> UserInput? {
                    guard
                        let name = String(args["name"] ?? .null)
                    else { 
                        return nil 
                    }
                    
                    return UserInput(name: name)
                }
            }
            """,
            macros: [
                "InputSchema": InputSchemaMacro.self,
                "SchemaField": SchemaFieldMacro.self
            ]
        )
    }
    
    func testOutputSchemaMacro() throws {
        assertMacroExpansion(
            """
            @OutputSchema
            struct UserOutput {
                @SchemaField(description: "User response")
                let response: String
            }
            """,
            expandedSource: """
            struct UserOutput {
                @SchemaField(description: "User response")
                let response: String
            }
            
            extension UserOutput {
                public static var outputSchema: MCP.Value {
                    .object([
                        "type": .string("object"),
                        "properties": .object([
                            "response": .object(["type": .string("string"), "description": .string("User response")])
                        ]),
                        "required": .array([.string("response")])
                    ])
                }
            }
            """,
            macros: [
                "OutputSchema": OutputSchemaMacro.self,
                "SchemaField": SchemaFieldMacro.self
            ]
        )
    }
}
