import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxBuilder

// MARK: - Schema Macro
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

// MARK: - Schema Field Information
struct SchemaFieldInfo {
    // Field name. Used as the key in JSON Schema properties and to read from args during parsing.
    let name: String
    // Original Swift type string (may include ? or array syntax). Used to decide unwrap strategy and JSON Schema type.
    let type: String
    // Optional description. Emitted to JSON Schema as "description".
    let description: String?
    // Business-level required flag:
    // - Drives inputSchema "required" list
    // - Decides whether parsing uses guard
    // Rule: non-optional type AND no default value => true; otherwise false
    let isRequiredField: Bool
    // Type-level optionality only. True if the Swift type ends with '?'.
    // It only affects how we unwrap/convert values, not whether we guard.
    let isOptionalType: Bool
    // Extra constraints for JSON Schema (minimum/maximum/enum/minItems/maxItems).
    let constraint: FieldConstraintInfo?

    init(
        name: String,
        type: String,
        description: String? = nil,
        isRequiredField: Bool = true,
        constraint: FieldConstraintInfo? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequiredField = isRequiredField
        self.isOptionalType = type.hasSuffix("?")
        self.constraint = constraint
    }
}

// MARK: - Constraint Validation (compile-time)

private func validateConstraints(for fields: [SchemaFieldInfo]) throws {
    for field in fields {
        guard let constraint = field.constraint else { continue }
        let swiftType = SwiftType(from: field.type)

        func error(_ message: String) throws -> Never { throw MacroError.unsupportedType(message) }
        let isWhole: (Double) -> Bool = { $0.rounded() == $0 }

        switch swiftType {
        case .optional(let wrapped):
            try validateConstraints(for: [SchemaFieldInfo(name: field.name, type: wrapped.baseTypeName, description: field.description, isRequiredField: field.isRequiredField, constraint: field.constraint)])
        case .basic(let basicType):
            switch basicType {
            case .string:
                switch constraint.type {
                case .range(let min, let max):
                    guard isWhole(min), isWhole(max) else {
                        try error("Property '\(field.name)' of type String requires integer length bounds for .range")
                    }
                case .options:
                    break
                }
            case .int:
                switch constraint.type {
                case .range(let min, let max):
                    guard isWhole(min), isWhole(max) else {
                        try error("Property '\(field.name)' of type Int requires integer bounds for .range")
                    }
                case .options:
                    break
                }
            case .double, .float:
                switch constraint.type {
                case .range:
                    break
                case .options:
                    break
                }
            case .bool:
                try error("Property '\(field.name)' of type Bool does not support range constraints")
            }
        case .array:
            switch constraint.type {
            case .range(let min, let max):
                guard isWhole(min), isWhole(max) else {
                    try error("Property '\(field.name)' of array type requires integer item count bounds for .range")
                }
            case .options:
                break
            }
        case .custom:
            switch constraint.type {
            case .range:
                try error("Property '\(field.name)' of custom type does not support range constraints")
            case .options:
                break
            }
        }
    }
}

// MARK: - Field Constraint Information
struct FieldConstraintInfo {
    enum ConstraintType {
        // Unified range with Double bounds; integrality is validated per-type where required.
        // - String: min/max must be integers → minLength/maxLength
        // - Array:  min/max must be integers → minItems/maxItems
        // - Int:    min/max must be integers → minimum/maximum (integer)
        // - Double/Float: doubles allowed     → minimum/maximum (number)
        case range(min: Double, max: Double)
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
            var constraint: FieldConstraintInfo? = nil
            let hasDefaultValue = binding.initializer != nil

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

            // Determine isRequired solely by type optionality and presence of a default value
            // optional OR has default -> not required; non-optional AND no default -> required
            let finalIsRequired = !propertyType.hasSuffix("?") && !hasDefaultValue

            fieldInfos.append(SchemaFieldInfo(
                name: propertyName,
                type: propertyType,
                description: description,
                isRequiredField: finalIsRequired,
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

// Indent constants for formatting
private let SCHEMA_INDENT = indent(IndentLevel.schema)
private let PROPERTY_INDENT = indent(IndentLevel.property)

private func generateAdvancedSchemaProperties(from properties: [SchemaFieldInfo], in root: Syntax) -> String {
    return properties.map { property in
        let swiftType = SwiftType(from: property.type)
        let schemaValue = schemaForProperty(type: swiftType, description: property.description, constraint: property.constraint)
        return "\"\(property.name)\": \(schemaValue)"
    }.joined(separator: ",\n\(SCHEMA_INDENT)")
}

// Generate the schema value for a property (right-hand side of the "name": ... pair)
private func schemaForProperty(type: SwiftType, description: String?, constraint: FieldConstraintInfo?) -> String {
    switch type {
    case .optional(let wrapped):
        // Optionality is handled by the "required" array; schema is of the wrapped type
        return schemaForProperty(type: wrapped, description: description, constraint: constraint)
    case .basic(let basicType):
        var components: [String] = ["\"type\": .string(\"\(basicType.jsonSchemaType)\")"]
        if let description = description {
            components.append("\"description\": .string(\"\(description)\")")
        }
        if let constraint = constraint {
            switch constraint.type {
            case .range(let min, let max):
                if basicType == .string {
                    components.append("\"minLength\": .int(\(Int(min)))")
                    components.append("\"maxLength\": .int(\(Int(max)))")
                } else if basicType == .double || basicType == .float {
                    components.append("\"minimum\": .double(\(min))")
                    components.append("\"maximum\": .double(\(max))")
                } else {
                    components.append("\"minimum\": .int(\(Int(min)))")
                    components.append("\"maximum\": .int(\(Int(max)))")
                }
            case .options(let values):
                let enumValuesString = values.map { ".string(\"\($0)\")" }.joined(separator: ", ")
                components.append("\"enum\": .array([\(enumValuesString)])")
            }
        }
        let body = components.joined(separator: ",\n\(PROPERTY_INDENT)")
        return ".object([\n\(PROPERTY_INDENT)\(body)\n\(SCHEMA_INDENT)])"
    case .array(let element):
        var components: [String] = ["\"type\": .string(\"array\")"]
        let itemSchema = schemaForItems(type: element)
        components.append("\"items\": \(itemSchema)")
        if let description = description {
            components.append("\"description\": .string(\"\(description)\")")
        }
        if let constraint = constraint {
            switch constraint.type {
            case .range(let min, let max):
                components.append("\"minItems\": .int(\(Int(min)))")
                components.append("\"maxItems\": .int(\(Int(max)))")
            case .options:
                // options is not typically used for arrays; ignore
                break
            }
        }
        let body = components.joined(separator: ",\n\(PROPERTY_INDENT)")
        return ".object([\n\(PROPERTY_INDENT)\(body)\n\(SCHEMA_INDENT)])"
    case .custom(let name):
        return "\(name).inputSchema"
    }
}

// Generate schema for array items
private func schemaForItems(type: SwiftType) -> String {
    switch type {
    case .optional(let wrapped):
        return schemaForItems(type: wrapped)
    case .basic(let basicType):
        return ".object([\"type\": .string(\"\(basicType.jsonSchemaType)\")])"
    case .array(let nested):
        let nestedItems = schemaForItems(type: nested)
        return ".object([\"type\": .string(\"array\"), \"items\": \(nestedItems)])"
    case .custom(let name):
        return "\(name).inputSchema"
    }
}

private func generateRequiredFields(from properties: [SchemaFieldInfo]) -> String {
    let requiredFields = properties.filter { $0.isRequiredField }.map { ".string(\"\($0.name)\")" }
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
    
    // Split required and optional via isRequiredField for consistency
    let requiredFields = schemaFields.filter { $0.isRequiredField }
    let optionalFields = schemaFields.filter { !$0.isRequiredField }
    
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
        // Fallback for unexpected optional typing
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
        // Fallback for nested optionals
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
        // Fallback: required optional
        return ("\(varName) = /* TODO: Required optional */ nil", nil)
    }
}

private func generateSchemaTypeChecks(for properties: [SchemaFieldInfo]) -> [String] {
    var schemaCheckLines: [String] = []
    var checkedTypes: Set<String> = []
    
    func collectSchemaCheck(for type: SwiftType) {
        switch type {
        case .basic:
            // No schema check for basic types
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
            // Use parsed value for @Field property
            let varName = "parsed\(fieldProperty.name.prefix(1).uppercased())\(fieldProperty.name.dropFirst())"
            return "\(propertyInfo.name): \(varName)"
        } else {
            // For non-@Field, handle by defaults and optionality
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
    
    try validateConstraints(for: classification.schemaFields)

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
            // Parse .range(0...120) or .range(0.0...1.0)
            if let rangeArg = functionCall.arguments.first?.expression {
                return parseRangeConstraintFromExpression(rangeArg)
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
            
            // Parse both integer and floating ranges as Double; integrality is validated later per type
            if let minDouble = Double(minStr), let maxDouble = Double(maxStr) {
                return FieldConstraintInfo(.range(min: minDouble, max: maxDouble))
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
