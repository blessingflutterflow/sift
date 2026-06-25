/// A dark, de-cluttered Google Maps style — empty streets, no POIs/labels
/// noise — so the orange route + markers pop. Applied via GoogleMap(style:).
const String kDarkMapStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#1d2026"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#9aa0aa"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#1d2026"}]},
  {"featureType":"administrative","elementType":"geometry","stylers":[{"visibility":"off"}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#222831"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#2a2f38"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#23272f"}]},
  {"featureType":"road","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#333a45"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#272c34"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#11141a"}]}
]
''';
