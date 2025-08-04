import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct MCPToolMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SchemaFieldMacro.self,
        InputSchemaMacro.self,
        OutputSchemaMacro.self,
        SchemaMacro.self,
        FieldMacro.self,
    ]
}
