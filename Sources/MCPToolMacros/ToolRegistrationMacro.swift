import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxBuilder

// MARK: - Schema Field Information
struct SchemaFieldInfo {
    let name: String
    let type: String
    let description: String?
    let enumValues: [String]?
    let isRequired: Bool
    let isOptional: Bool
    
    init(name: String, type: String, description: String? = nil, enumValues: [String]? = nil, isRequired: Bool = true) {
        self.name = name
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.isRequired = isRequired
        self.isOptional = type.hasSuffix("?")
    }
}


// MARK: - Helper Methods

private func extractSchemaFields(from structDecl: StructDeclSyntax) -> [SchemaFieldInfo] {
    return structDecl.memberBlock.members.compactMap { member -> SchemaFieldInfo? in
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
              let binding = varDecl.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              let typeAnnotation = binding.typeAnnotation else {
            return nil
        }
        
        let propertyName = pattern.identifier.text
        let propertyType = typeAnnotation.type.trimmed.description
        
        // Extract Field attributes if present
        var description: String?
        var enumValues: [String]?
        var isRequired = !propertyType.hasSuffix("?")
        
        for attribute in varDecl.attributes {
            if let attributeNode = attribute.as(AttributeSyntax.self),
               let identifier = attributeNode.attributeName.as(IdentifierTypeSyntax.self),
               (identifier.name.text == "SchemaField" || identifier.name.text == "Field") {
                
                // Parse SchemaField or Field arguments
                if let arguments = attributeNode.arguments?.as(LabeledExprListSyntax.self) {
                    for argument in arguments {
                        switch argument.label?.text {
                        case "description":
                            if let stringLiteral = argument.expression.as(StringLiteralExprSyntax.self),
                               let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
                                description = segment.content.text
                            }
                        case "validOptions", "enum":
                            if let arrayExpr = argument.expression.as(ArrayExprSyntax.self) {
                                enumValues = arrayExpr.elements.compactMap { element in
                                    if let stringLiteral = element.expression.as(StringLiteralExprSyntax.self),
                                       let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
                                        return segment.content.text
                                    }
                                    return nil
                                }
                            }
                        case "isRequired":
                            if let boolLiteral = argument.expression.as(BooleanLiteralExprSyntax.self) {
                                isRequired = boolLiteral.literal.text == "true"
                            }
                        default:
                            break
                        }
                    }
                }
            }
        }
        
        return SchemaFieldInfo(
            name: propertyName,
            type: propertyType,
            description: description,
            enumValues: enumValues,
            isRequired: isRequired
        )
    }
}


private func generateAdvancedSchemaProperties(from properties: [SchemaFieldInfo], in root: Syntax) throws -> String {
    return try properties.map { property in
        let baseType = property.type.replacingOccurrences(of: "?", with: "")
        if let jsonSchemaType = swiftTypeToJsonSchemaType(baseType) {
            var schemaComponents: [String] = ["\"type\": .string(\"\(jsonSchemaType)\")"]

            if let description = property.description {
                schemaComponents.append("\"description\": .string(\"\(description)\")")
            }

            if let enumValues = property.enumValues, !enumValues.isEmpty {
                let enumValuesString = enumValues.map { ".string(\"\($0)\")" }.joined(separator: ", ")
                schemaComponents.append("\"enum\": .array([\(enumValuesString)])")
            }

            let schemaString = schemaComponents.joined(separator: ", ")
            return "                            \"\(property.name)\": .object([\(schemaString)])"
        } else if isSchemaAnnotatedType(baseType, in: root) {
            return "                            \"\(property.name)\": \(baseType).inputSchema"
        } else {
            throw MacroError.unsupportedType("Unsupported type \(property.type) for property \(property.name)")
        }
    }.joined(separator: ",\n")
}

private func generateRequiredFields(from properties: [SchemaFieldInfo]) -> String {
    let requiredFields = properties.filter { $0.isRequired }.map { ".string(\"\($0.name)\")" }
    return requiredFields.joined(separator: ", ")
}



private func swiftTypeToJsonSchemaType(_ swiftType: String) -> String? {
    switch swiftType {
    case "String":
        return "string"
    case "Int":
        return "integer"
    case "Double", "Float":
        return "number"
    case "Bool":
        return "boolean"
    default:
        return nil
    }
}

private func isSchemaAnnotatedType(_ typeName: String, in root: Syntax) -> Bool {
    class Finder: SyntaxVisitor {
        let typeName: String
        var found = false

        init(typeName: String) {
            self.typeName = typeName
            super.init(viewMode: .all)
        }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            if node.name.text == typeName {
                if let attrs = node.attributes {
                    for attr in attrs {
                        if let attr = attr.as(AttributeSyntax.self),
                           let id = attr.attributeName.as(IdentifierTypeSyntax.self),
                           id.name.text == "Schema" {
                            found = true
                            return .skipChildren
                        }
                    }
                }
            }
            return .visitChildren
        }
    }

    let finder = Finder(typeName: typeName)
    finder.walk(root)
    return finder.found
}


// MARK: - Schema Macro (Simpler API)

public struct SchemaMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw MacroError.invalidDeclaration("@Schema can only be applied to structs")
        }
        
        let properties = extractSchemaFields(from: structDecl)
        var root: Syntax = Syntax(structDecl)
        while let parent = root.parent { root = parent }

        let schemaProperties = try generateAdvancedSchemaProperties(from: properties, in: root)
        let requiredFields = generateRequiredFields(from: properties)

        let propertyExtractions = try properties.map { property in
            let varName = "parsed\(property.name.prefix(1).uppercased())\(property.name.dropFirst())"
            if property.isOptional {
                let baseType = property.type.replacingOccurrences(of: "?", with: "")
                if swiftTypeToJsonSchemaType(baseType) != nil {
                    return "let \(varName) = \(baseType)(args[\"\(property.name)\"] ?? .null)"
                } else if isSchemaAnnotatedType(baseType, in: root) {
                    return "let \(varName) = args[\"\(property.name)\"].flatMap { \(baseType).parseArguments($0.objectValue ?? Dictionary<String, MCP.Value>()) }"
                } else {
                    throw MacroError.unsupportedType("Unsupported type \(property.type) for property \(property.name)")
                }
            } else {
                if swiftTypeToJsonSchemaType(property.type) != nil {
                    return "let \(varName) = \(property.type)(args[\"\(property.name)\"] ?? .null)"
                } else if isSchemaAnnotatedType(property.type, in: root) {
                    return "let \(varName) = \(property.type).parseArguments(args[\"\(property.name)\"]?.objectValue ?? Dictionary<String, MCP.Value>())"
                } else {
                    throw MacroError.unsupportedType("Unsupported type \(property.type) for property \(property.name)")
                }
            }
        }.joined(separator: ",\n                    ")
        
        let propertyList = properties.map { property in
            let varName = "parsed\(property.name.prefix(1).uppercased())\(property.name.dropFirst())"
            return "\(property.name): \(varName)"
        }.joined(separator: ", ")
        
        let extensionDecl: ExtensionDeclSyntax = try ExtensionDeclSyntax("""
        extension \(type): MCP.MCPParameterParsable {
            public static var inputSchema: MCP.Value {
                .object([
                    "type": .string("object"),
                    "properties": .object([
        \(raw: schemaProperties)
                    ])\(raw: requiredFields.isEmpty ? "" : ",\n                    \"required\": .array([\(requiredFields)])")
                ])
            }
            
            public static func parseArguments(_ args: [String: MCP.Value]) -> \(type)? {
                guard
                    \(raw: propertyExtractions)
                else { 
                    return nil 
                }
                
                return \(type)(\(raw: propertyList))
            }
        }
        """)
        
        return [extensionDecl]
    }
}

// MARK: - Field Macro (Simpler API)

public struct FieldMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Field is primarily used as an annotation for @Schema
        // It doesn't generate additional code itself
        return []
    }
}

// MARK: - Error Types

enum MacroError: Error, CustomStringConvertible {
    case invalidDeclaration(String)
    case missingArguments(String)
    case unsupportedType(String)
    
    var description: String {
        switch self {
        case .invalidDeclaration(let message):
            return "Invalid declaration: \(message)"
        case .missingArguments(let message):
            return "Missing arguments: \(message)"
        case .unsupportedType(let message):
            return "Unsupported type: \(message)"
        }
    }
}
