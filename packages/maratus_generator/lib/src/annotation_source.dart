import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

/// A constant expression copied from an annotation argument.
final class CopiedExpression {
  /// Creates a copied expression with its [source] and [freeNames].
  const CopiedExpression(this.source, this.freeNames);

  /// The source of the expression, valid anywhere in its library.
  ///
  /// It is a constant expression, but it needs a constant context, such as
  /// the initializer of a `const` variable, to be evaluated as one.
  final String source;

  /// The names that the expression looks up in the library's scope, which a
  /// declaration of the same name in an enclosing scope would shadow.
  final Set<String> freeNames;

  /// Whether a scope declaring [names] would shadow a name this expression
  /// uses.
  bool isShadowedBy(Set<String> names) => freeNames.any(names.contains);
}

/// Copies the source of annotation arguments, using the resolved syntax of
/// the annotated declarations.
final class AnnotationSources {
  /// Reads declarations through the resolver of a build step.
  AnnotationSources(this._buildStep);

  final BuildStep _buildStep;

  /// Copies an argument of the first [annotation] of [element]: the
  /// [positional] argument at that index, or the argument [named].
  ///
  /// References to static members that the annotation makes without naming
  /// their class are qualified with it, so the copy is valid outside the
  /// class. Throws an [InvalidGenerationSourceError] if the argument is
  /// missing.
  Future<CopiedExpression> argument(
    Element element,
    TypeChecker annotation, {
    int? positional,
    String? named,
  }) async {
    final node = await _buildStep.resolver.astNodeFor(
      element.firstFragment,
      resolve: true,
    );
    for (final candidate in _metadataOf(node) ?? const <Annotation>[]) {
      final type = candidate.elementAnnotation?.computeConstantValue()?.type;
      if (type == null || !annotation.isExactlyType(type)) continue;
      var index = 0;
      for (final AstNode argument
          in candidate.arguments?.arguments ?? const <AstNode>[]) {
        final name = _nameOf(argument);
        final matches = name == null ? index++ == positional : name == named;
        if (matches) return _copy(argument, skipName: name != null);
      }
    }
    throw InvalidGenerationSourceError(
      'Could not read the source of an annotation argument.',
      element: element,
    );
  }

  static List<Annotation>? _metadataOf(AstNode? node) {
    // The annotations of a field belong to its whole declaration.
    if (node is VariableDeclaration) node = node.parent?.parent;
    if (node is AnnotatedNode) return node.metadata;
    if (node is FormalParameter) return node.metadata;
    return null;
  }

  /// The name of a named [argument], or `null` for a positional one.
  static String? _nameOf(AstNode argument) {
    final first = argument.beginToken;
    final next = first.next;
    return first.isIdentifier &&
            next != null &&
            next.type == TokenType.COLON &&
            next.offset < argument.end
        ? first.lexeme
        : null;
  }

  static CopiedExpression _copy(AstNode argument, {required bool skipName}) {
    final references = _References();
    argument.accept(references);
    Token? token = argument.beginToken;
    if (skipName) token = token.next?.next;
    final end = argument.endToken.end;
    final buffer = StringBuffer();
    Token? previous;
    while (token != null && !token.isEof) {
      // Whitespace and comments between tokens become one space.
      if (previous != null && token.offset > previous.end) buffer.write(' ');
      buffer
        ..write(references.qualifiers[token.offset] ?? '')
        ..write(token.lexeme);
      if (token.end >= end) break;
      previous = token;
      token = token.next;
    }
    return CopiedExpression(buffer.toString(), references.freeNames);
  }
}

final class _References extends RecursiveAstVisitor<void> {
  final qualifiers = <int, String>{};
  final freeNames = <String>{};

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.element;
    final previous = node.token.previous?.type;
    final qualified =
        node.isQualified ||
        previous == TokenType.PERIOD ||
        previous == TokenType.QUESTION_PERIOD;
    if (!qualified && element != null) {
      final enclosing = element.enclosingElement;
      final name = enclosing?.name;
      if (enclosing is InstanceElement && _isStatic(element) && name != null) {
        // A class body sees its static members without their class name.
        qualifiers[node.offset] = '$name.';
      } else if (enclosing is LibraryElement || element is PrefixElement) {
        freeNames.add(node.name);
      }
    }
    super.visitSimpleIdentifier(node);
  }

  static bool _isStatic(Element element) =>
      (element is ExecutableElement && element.isStatic) ||
      (element is FieldElement && element.isStatic);
}
