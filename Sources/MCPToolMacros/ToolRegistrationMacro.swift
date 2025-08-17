import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxBuilder

// MARK: - Schema Field Information
struct SchemaFieldInfo {
    let name: String
    let type: String
    let description: String?
    let isRequired: Bool
    let isOptional: Bool
    let constraint: FieldConstraintInfo?

    init(
        name: String,
        type: String,
        description: String? = nil,
        isRequired: Bool = true,
        constraint: FieldConstraintInfo? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
        self.isOptional = type.hasSuffix("?")
        self.constraint = constraint
    }
}

// MARK: - Field Constraint Information
struct FieldConstraintInfo {
    enum ConstraintType {
        case range(min: Int, max: Int)
        case rangeDouble(min: Double, max: Double)
        case count(value: Int)
        case options([String])
    }

    let type: ConstraintType

    init(_ type: ConstraintType) {
        self.type = type
    }
}

// MARK: - Helper Methods

// Describes basic information about all properties
struct PropertyInfo {
    let name: String
    let type: String
    let isOptional: Bool
    let hasDefaultValue: Bool
}

private func extractAllProperties(from structDecl: StructDeclSyntax) -> [PropertyInfo] {
    var allProperties: [PropertyInfo] = []

    for member in structDecl.memberBlock.members {
        if let varDecl = member.decl.as(VariableDeclSyntax.self),
           let binding = varDecl.bindings.first,
           let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
           let typeAnnotation = binding.typeAnnotation {

            let propertyName = pattern.identifier.text
            let propertyType = typeAnnotation.type.trimmed.description
            let isOptional = propertyType.hasSuffix("?")
            let hasDefaultValue = binding.initializer != nil

            allProperties.append(PropertyInfo(
                name: propertyName,
                type: propertyType,
                isOptional: isOptional,
                hasDefaultValue: hasDefaultValue
            ))
        }
    }
    return allProperties
}

private func extractSchemaFields(from structDecl: StructDeclSyntax) -> [SchemaFieldInfo] {
    // Approach A: Parse @Field marked properties directly (following Foundation Models pattern)
    var fieldInfos: [SchemaFieldInfo] = []
    
    for member in structDecl.memberBlock.members {
        if let varDecl = member.decl.as(VariableDeclSyntax.self),
           let binding = varDecl.bindings.first,
           let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
           let typeAnnotation = binding.typeAnnotation {

            // Check if property has @Field attribute
            let hasFieldAttribute = varDecl.attributes.contains { attribute in
                if let attributeNode = attribute.as(AttributeSyntax.self),
                   let identifier = attributeNode.attributeName.as(IdentifierTypeSyntax.self) {
                    return identifier.name.text == "Field"
                }
                return false
            }

            guard hasFieldAttribute else { continue }

            let propertyName = pattern.identifier.text
            let propertyType = typeAnnotation.type.trimmed.description
            var description: String?
            var isRequired: Bool? = nil
            var constraint: FieldConstraintInfo? = nil

            for attribute in varDecl.attributes {
                if let attributeNode = attribute.as(AttributeSyntax.self),
                   let identifier = attributeNode.attributeName.as(IdentifierTypeSyntax.self),
                   identifier.name.text == "Field" {
                    
                    if let arguments = attributeNode.arguments?.as(LabeledExprListSyntax.self) {
                        for argument in arguments {
                            switch argument.label?.text {
                            case "description":
                                if let stringLiteral = argument.expression.as(StringLiteralExprSyntax.self),
                                   let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
                                    description = segment.content.text
                                }
                            case "isRequired":
                                if let boolLiteral = argument.expression.as(BooleanLiteralExprSyntax.self) {
                                    isRequired = boolLiteral.literal.text == "true"
                                }
                            case "constraint":
                                // Parse FieldConstraint enum value
                                constraint = parseFieldConstraint(argument.expression)
                            default:
                                break
                            }
                        }
                    }
                }
            }

            // If isRequired not specified, infer from property type
            let finalIsRequired = isRequired ?? !propertyType.hasSuffix("?")

            fieldInfos.append(SchemaFieldInfo(
                name: propertyName,
                type: propertyType,
                description: description,
                isRequired: finalIsRequired,
                constraint: constraint
            ))
        }
    }
    return fieldInfos
}

// MARK: - String Template System

private func indent(_ level: Int) -> String {
    return String(repeating: "    ", count: level)
}

private struct IndentLevel {
    static let schema = 4      // 16 spaces for schema level
    static let property = 5    // 20 spaces for property level
}

// Legacy constants for compatibility
private let SCHEMA_INDENT = indent(IndentLevel.schema)
private let PROPERTY_INDENT = indent(IndentLevel.property)

private func generateAdvancedSchemaProperties(from properties: [SchemaFieldInfo], in root: Syntax) -> String {
    return properties.map { property in
        let baseType = property.type.replacingOccurrences(of: "?", with: "")
        if let jsonSchemaType = swiftTypeToJsonSchemaType(baseType) {
            var schemaComponents: [String] = ["\"type\": .string(\"\(jsonSchemaType)\")"]

            if let description = property.description {
                schemaComponents.append("\"description\": .string(\"\(description)\")")
            }

            // Add constraint properties to JSON Schema
            if let constraint = property.constraint {
                switch constraint.type {
                case .range(let min, let max):
                    schemaComponents.append("\"minimum\": .int(\(min))")
                    schemaComponents.append("\"maximum\": .int(\(max))")
                case .rangeDouble(let min, let max):
                    schemaComponents.append("\"minimum\": .double(\(min))")
                    schemaComponents.append("\"maximum\": .double(\(max))")
                case .count(_):
                    // This will be handled in array processing section
                    break
                case .options(let values):
                    let enumValuesString = values.map { ".string(\"\($0)\")" }.joined(separator: ", ")
                    schemaComponents.append("\"enum\": .array([\(enumValuesString)])")
                }
            }

            let schemaString = schemaComponents.joined(separator: ",\n\(PROPERTY_INDENT)")
            return "\"\(property.name)\": .object([\n\(PROPERTY_INDENT)\(schemaString)\n\(SCHEMA_INDENT)])"
        } else if baseType.hasPrefix("[") && baseType.hasSuffix("]") {
            // Handle array types
            let elementType = String(baseType.dropFirst().dropLast()) // Remove [ and ]
            if let jsonSchemaType = swiftTypeToJsonSchemaType(elementType) {
                var schemaComponents: [String] = ["\"type\": .string(\"array\")"]
                schemaComponents.append("\"items\": .object([\"type\": .string(\"\(jsonSchemaType)\")])")

                if let description = property.description {
                    schemaComponents.append("\"description\": .string(\"\(description)\")")
                }

                // Add array-specific constraints
                if let constraint = property.constraint {
                    switch constraint.type {
                    case .count(let value):
                        schemaComponents.append("\"minItems\": .int(\(value))")
                        schemaComponents.append("\"maxItems\": .int(\(value))")
                    default:
                        break
                    }
                }

                let schemaString = schemaComponents.joined(separator: ",\n\(PROPERTY_INDENT)")
                return "\"\(property.name)\": .object([\n\(PROPERTY_INDENT)\(schemaString)\n\(SCHEMA_INDENT)])"
            } else {
                // Assume nested @Schema type; let the compiler enforce conformance via helper
                var schemaComponents: [String] = ["\"type\": .string(\"array\")"]
                schemaComponents.append("\"items\": \(elementType).inputSchema")

                if let description = property.description {
                    schemaComponents.append("\"description\": .string(\"\(description)\")")
                }

                let schemaString = schemaComponents.joined(separator: ",\n\(PROPERTY_INDENT)")
                return "\"\(property.name)\": .object([\n\(PROPERTY_INDENT)\(schemaString)\n\(SCHEMA_INDENT)])"
            }
        } else {
            return "\"\(property.name)\": \(baseType).inputSchema"
        }
    }.joined(separator: ",\n\(SCHEMA_INDENT)")
}

private func generateRequiredFields(from properties: [SchemaFieldInfo]) -> String {
    let requiredFields = properties.filter { $0.isRequired }.map { ".string(\"\($0.name)\")" }
    return requiredFields.joined(separator: ",\n\(SCHEMA_INDENT)")
}

// MARK: - Property Classification

struct PropertyClassification {
    let schemaFields: [SchemaFieldInfo]
    let optionalFields: [SchemaFieldInfo]
    let requiredFields: [SchemaFieldInfo]
    let allProperties: [PropertyInfo]
}

private func classifyProperties(from structDecl: StructDeclSyntax) -> PropertyClassification {
    let schemaFields = extractSchemaFields(from: structDecl)
    let allProperties = extractAllProperties(from: structDecl)
    
    let optionalFields = schemaFields.filter { $0.isOptional }
    let requiredFields = schemaFields.filter { !$0.isOptional }
    
    return PropertyClassification(
        schemaFields: schemaFields,
        optionalFields: optionalFields,
        requiredFields: requiredFields,
        allProperties: allProperties
    )
}

// MARK: - Parsing Logic Generation

struct ParsingLogic {
    let optionalExtractions: [String]
    let requiredGuardBindings: [String]
    let requiredPostGuardLines: [String]
    let schemaCheckLines: [String]
    let propertyList: String
}

private func generateParsingLogic(
    for classification: PropertyClassification
) throws -> ParsingLogic {
    
    // Optional field extractions
    let optionalExtractions = classification.optionalFields.map { property in
        return generateOptionalExtraction(for: property)
    }
    
    // Required field processing
    var requiredGuardBindings: [String] = []
    var requiredPostGuardLines: [String] = []
    
    for property in classification.requiredFields {
        let (guardBinding, postGuardLine) = generateRequiredFieldLogic(for: property)
        requiredGuardBindings.append(guardBinding)
        if let postGuard = postGuardLine {
            requiredPostGuardLines.append(postGuard)
        }
    }
    
    // Schema type checking
    let schemaCheckLines = generateSchemaTypeChecks(for: classification.schemaFields)
    
    // Constructor property list
    let propertyList = try generatePropertyConstructorList(
        schemaFields: classification.schemaFields,
        allProperties: classification.allProperties
    )
    
    return ParsingLogic(
        optionalExtractions: optionalExtractions,
        requiredGuardBindings: requiredGuardBindings,
        requiredPostGuardLines: requiredPostGuardLines,
        schemaCheckLines: schemaCheckLines,
        propertyList: propertyList
    )
}

private func generateOptionalExtraction(for property: SchemaFieldInfo) -> String {
    let varName = "parsed\(property.name.prefix(1).uppercased())\(property.name.dropFirst())"
    let swiftType = SwiftType(from: property.type)
    
    switch swiftType {
    case .optional(let wrapped):
        return generateOptionalExtractionForType(varName: varName, propertyName: property.name, type: wrapped)
    default:
        // This shouldn't happen for optional properties, but handle gracefully
        return generateOptionalExtractionForType(varName: varName, propertyName: property.name, type: swiftType)
    }
}

private func generateOptionalExtractionForType(varName: String, propertyName: String, type: SwiftType) -> String {
    switch type {
    case .basic(let basicType):
        return "let \(varName) = \(basicType.rawValue)(args[\"\(propertyName)\"] ?? .null)"
    case .array(let element):
        switch element {
        case .basic(let basicType):
            return "let \(varName) = args[\"\(propertyName)\"]?.arrayValue?.compactMap({ \(basicType.rawValue)($0) })"
        case .custom(let typeName):
            return "let \(varName) = args[\"\(propertyName)\"]?.arrayValue?.compactMap({ \(typeName).parseArguments($0.objectValue ?? [:]) })"
        default:
            return "let \(varName) = args[\"\(propertyName)\"]?.arrayValue?.compactMap({ /* TODO: Complex array element */ })"
        }
    case .custom(let typeName):
        return "let \(varName) = args[\"\(propertyName)\"].flatMap { \(typeName).parseArguments($0.objectValue ?? Dictionary<String, MCP.Value>()) }"
    case .optional:
        // Nested optionals, shouldn't happen in well-formed types
        return "let \(varName) = args[\"\(propertyName)\"] /* TODO: Nested optional */"
    }
}

private func generateRequiredFieldLogic(for property: SchemaFieldInfo) -> (String, String?) {
    let varName = "parsed\(property.name.prefix(1).uppercased())\(property.name.dropFirst())"
    let swiftType = SwiftType(from: property.type)
    
    switch swiftType {
    case .basic(let basicType):
        return ("\(varName) = \(basicType.rawValue)(args[\"\(property.name)\"] ?? .null)", nil)
    case .array(let element):
        let rawName = "raw\(property.name.prefix(1).uppercased())\(property.name.dropFirst())"
        let guardBinding = "\(rawName) = args[\"\(property.name)\"]?.arrayValue"
        
        switch element {
        case .basic(let basicType):
            let postGuard = "let \(varName) = \(rawName).compactMap({ \(basicType.rawValue)($0) })"
            return (guardBinding, postGuard)
        case .custom(let typeName):
            let postGuard = "let \(varName) = \(rawName).compactMap({ \(typeName).parseArguments($0.objectValue ?? [:]) })"
            return (guardBinding, postGuard)
        default:
            let postGuard = "let \(varName) = \(rawName) /* TODO: Complex array element */"
            return (guardBinding, postGuard)
        }
    case .custom(let typeName):
        return ("\(varName) = \(typeName).parseArguments(args[\"\(property.name)\"]?.objectValue ?? Dictionary<String, MCP.Value>())", nil)
    case .optional:
        // Required fields shouldn't be optional, but handle gracefully
        return ("\(varName) = /* TODO: Required optional */ nil", nil)
    }
}

private func generateSchemaTypeChecks(for properties: [SchemaFieldInfo]) -> [String] {
    var schemaCheckLines: [String] = []
    var checkedTypes: Set<String> = []
    
    func collectSchemaCheck(for type: SwiftType) {
        switch type {
        case .basic:
            // No schema check needed for basic types
            break
        case .array(let element):
            collectSchemaCheck(for: element)
        case .optional(let wrapped):
            collectSchemaCheck(for: wrapped)
        case .custom(let typeName):
            if !checkedTypes.contains(typeName) {
                checkedTypes.insert(typeName)
                schemaCheckLines.append("_requireSchema(\(typeName).self)")
            }
        }
    }
    
    for property in properties {
        let swiftType = SwiftType(from: property.type)
        collectSchemaCheck(for: swiftType)
    }
    
    return schemaCheckLines
}

private func generatePropertyConstructorList(
    schemaFields: [SchemaFieldInfo],
    allProperties: [PropertyInfo]
) throws -> String {
    return try allProperties.compactMap { propertyInfo -> String? in
        if let fieldProperty = schemaFields.first(where: { $0.name == propertyInfo.name }) {
            // @Field property - use parsed value
            let varName = "parsed\(fieldProperty.name.prefix(1).uppercased())\(fieldProperty.name.dropFirst())"
            return "\(propertyInfo.name): \(varName)"
        } else {
            // Non-@Field property - handle based on type and defaults
            if propertyInfo.hasDefaultValue {
                return nil // Skip properties with default values
            } else if propertyInfo.isOptional {
                return "\(propertyInfo.name): nil"
            } else {
                throw MacroError.missingArguments("Property '\(propertyInfo.name)' is non-optional and not marked with @Field or default value. Provide a default or mark it optional/@Field.")
            }
        }
    }.joined(separator: ",\n            ")
}

// MARK: - Extension Assembly

private func assembleExtension(
    for type: some TypeSyntaxProtocol,
    protocolName: String,
    schemaPropertyName: String,
    parseMethodName: String,
    parseMethodSignature: String,
    schemaProperties: String,
    requiredFields: String,
    parsingLogic: ParsingLogic
) throws -> ExtensionDeclSyntax {
    
    let extensionDecl: ExtensionDeclSyntax = try ExtensionDeclSyntax("""
    extension \(type): \(raw: protocolName) {
        public static var \(raw: schemaPropertyName): MCP.Value {
            .object([
                "type": .string("object"),
                "properties": .object([
                    \(raw: schemaProperties)
                ])\(raw: requiredFields.isEmpty ? "" : ",\n            \"required\": .array([\n\(SCHEMA_INDENT)\(requiredFields)\n            ])")
            ])
        }
        
        // Compile-time requirement: nested types must provide schema/parse via @Schema
        @available(*, unavailable, message: "Please annotate this type with @Schema to enable MCP schema and parsing.")
        private static func _requireSchema(_ type: Any.Type) {}
        private static func _requireSchema<T: MCP.MCPParameterParsable>(_ type: T.Type) {}
        
        \(raw: parseMethodSignature) {
            \(raw: parseMethodName == "parseArguments" ? "" : "guard let args = value.objectValue else {\n                return nil\n            }\n\n            ")\(raw: parsingLogic.schemaCheckLines.isEmpty ? "" : "\(parsingLogic.schemaCheckLines.joined(separator: "\n            "))\n\n            ")\(raw: parsingLogic.optionalExtractions.isEmpty ? "" : "\(parsingLogic.optionalExtractions.joined(separator: "\n            "))\n\n            ")\(raw: parsingLogic.requiredGuardBindings.isEmpty ? "" : "guard let \(parsingLogic.requiredGuardBindings.joined(separator: ",\n                let ")) else {\n                return nil\n            }\n\n            ")\(raw: parsingLogic.requiredPostGuardLines.isEmpty ? "" : "\(parsingLogic.requiredPostGuardLines.joined(separator: "\n            "))\n\n            ")

            return \(type)(
                \(raw: parsingLogic.propertyList)
            )
        }
    }
    """)
    
    return extensionDecl
}

// MARK: - Main Generation Function

private func generateSchemaExtension(
    for type: some TypeSyntaxProtocol,
    from structDecl: StructDeclSyntax,
    protocolName: String,
    schemaPropertyName: String,
    parseMethodName: String,
    parseMethodSignature: String
) throws -> ExtensionDeclSyntax {
    
    // 1. Classify properties
    let classification = classifyProperties(from: structDecl)
    
    // 2. Generate schema components
    var root: Syntax = Syntax(structDecl)
    while let parent = root.parent { root = parent }
    
    let schemaProperties = generateAdvancedSchemaProperties(from: classification.schemaFields, in: root)
    let requiredFields = generateRequiredFields(from: classification.schemaFields)
    
    // 3. Generate parsing logic
    let parsingLogic = try generateParsingLogic(for: classification)
    
    // 4. Assemble final extension
    return try assembleExtension(
        for: type,
        protocolName: protocolName,
        schemaPropertyName: schemaPropertyName,
        parseMethodName: parseMethodName,
        parseMethodSignature: parseMethodSignature,
        schemaProperties: schemaProperties,
        requiredFields: requiredFields,
        parsingLogic: parsingLogic
    )
}

// MARK: - Type Classification System

indirect enum SwiftType {
    case basic(BasicType)
    case array(element: SwiftType)
    case optional(wrapped: SwiftType)
    case custom(String)
    
    enum BasicType: String, CaseIterable {
        case string = "String"
        case int = "Int"
        case double = "Double"
        case float = "Float"
        case bool = "Bool"
        
        var jsonSchemaType: String {
            switch self {
            case .string: return "string"
            case .int: return "integer"
            case .double, .float: return "number"
            case .bool: return "boolean"
            }
        }
    }
    
    init(from typeString: String) {
        let cleanType = typeString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle optional types
        if cleanType.hasSuffix("?") {
            let wrappedType = String(cleanType.dropLast())
            self = .optional(wrapped: SwiftType(from: wrappedType))
            return
        }
        
        // Handle array types
        if cleanType.hasPrefix("[") && cleanType.hasSuffix("]") {
            let elementType = String(cleanType.dropFirst().dropLast())
            self = .array(element: SwiftType(from: elementType))
            return
        }
        
        // Handle basic types
        if let basicType = BasicType(rawValue: cleanType) {
            self = .basic(basicType)
            return
        }
        
        // Custom/nested types
        self = .custom(cleanType)
    }
    
    var jsonSchemaType: String? {
        switch self {
        case .basic(let basicType):
            return basicType.jsonSchemaType
        case .array:
            return "array"
        case .optional(let wrapped):
            return wrapped.jsonSchemaType
        case .custom:
            return nil
        }
    }
    
    var isBasicType: Bool {
        switch self {
        case .basic: return true
        case .optional(let wrapped): return wrapped.isBasicType
        default: return false
        }
    }
    
    var baseTypeName: String {
        switch self {
        case .basic(let basicType):
            return basicType.rawValue
        case .array(let element):
            return "[\(element.baseTypeName)]"
        case .optional(let wrapped):
            return wrapped.baseTypeName
        case .custom(let name):
            return name
        }
    }
}

private func swiftTypeToJsonSchemaType(_ swiftType: String) -> String? {
    return SwiftType(from: swiftType).jsonSchemaType
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

        let extensionDecl = try generateSchemaExtension(
            for: type,
            from: structDecl,
            protocolName: "MCP.MCPParameterParsable",
            schemaPropertyName: "inputSchema",
            parseMethodName: "parseArguments",
            parseMethodSignature: "public static func parseArguments(_ args: [String: MCP.Value]) -> \(type)?"
        )

        return [extensionDecl]
    }
}

// MARK: - Field Macro

public struct FieldMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Approach A: @Field is pure annotation, generates no code (following Foundation Models' @Guide)
        // All information will be parsed directly from AST during @Schema expansion
        return []
    }
}

// Parse FieldConstraint enum values
private func parseFieldConstraint(_ expression: ExprSyntax) -> FieldConstraintInfo? {
    // Handle formats like .options(["value1", "value2"])  
    if let functionCall = expression.as(FunctionCallExprSyntax.self),
       let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self) {
        
        let memberName = memberAccess.declName.baseName.text
        
        switch memberName {
        case "options":
            // Parse .options(["light", "dark"])
            if let arrayArg = functionCall.arguments.first?.expression.as(ArrayExprSyntax.self) {
                let options = arrayArg.elements.compactMap { element -> String? in
                    if let stringLiteral = element.expression.as(StringLiteralExprSyntax.self),
                       let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
                        return segment.content.text
                    }
                    return nil
                }
                if !options.isEmpty {
                    return FieldConstraintInfo(.options(options))
                }
            }
        case "range":
            // Parse .range(0...120)
            if let rangeArg = functionCall.arguments.first?.expression {
                return parseRangeConstraintFromExpression(rangeArg)
            }
        case "rangeDouble":
            // Parse .rangeDouble(0.0...100.0)
            if let rangeArg = functionCall.arguments.first?.expression {
                return parseRangeConstraintFromExpression(rangeArg)
            }
        case "count":
            // Parse .count(5)
            if let intArg = functionCall.arguments.first?.expression.as(IntegerLiteralExprSyntax.self),
               let value = Int(intArg.literal.text) {
                return FieldConstraintInfo(.count(value: value))
            }
        default:
            break
        }
    }
    return nil
}

// Combine duplicate constraint parsing logic
private func parseRangeConstraintFromExpression(_ expression: ExprSyntax) -> FieldConstraintInfo? {
    // Handle ClosedRange expressions uniformly (0...120, 0.0...100.0)
    if let sequenceExpr = expression.as(SequenceExprSyntax.self) {
        let elements = sequenceExpr.elements
        if elements.count >= 3,
           let minElement = elements.first?.as(ExprSyntax.self),
           let maxElement = elements.last?.as(ExprSyntax.self) {
            
            let minStr = minElement.trimmed.description
            let maxStr = maxElement.trimmed.description
            
            // Check if it's a floating point number
            if minStr.contains(".") || maxStr.contains(".") {
                if let minDouble = Double(minStr), let maxDouble = Double(maxStr) {
                    return FieldConstraintInfo(.rangeDouble(min: minDouble, max: maxDouble))
                }
            } else {
                if let minInt = Int(minStr), let maxInt = Int(maxStr) {
                    return FieldConstraintInfo(.range(min: minInt, max: maxInt))
                }
            }
        }
    }
    return nil
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
