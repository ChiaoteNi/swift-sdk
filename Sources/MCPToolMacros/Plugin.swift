import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct MCPToolMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SchemaMacro.self,
        FieldMacro.self,
    ]
}
