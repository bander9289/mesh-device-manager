class MeshGroup {
  final int id;
  final String name;
  final int colorValue; // ARGB color value
  MeshGroup({required this.id, required this.name, int? colorValue}) : colorValue = colorValue ?? 0xFF2196F3; // default blue
}
