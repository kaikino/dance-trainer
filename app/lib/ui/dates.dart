/// Short, friendly dates without a locale package: "Today 14:05",
/// "Yesterday 09:30", "Tue 3 Nov", "3 Nov 2025".
String friendlyDate(DateTime d, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final day = DateTime(d.year, d.month, d.day);
  final today = DateTime(n.year, n.month, n.day);
  final diff = today.difference(day).inDays;
  String two(int v) => v.toString().padLeft(2, '0');
  final time = '${two(d.hour)}:${two(d.minute)}';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  if (diff == 0) return 'Today $time';
  if (diff == 1) return 'Yesterday $time';
  if (diff > 1 && diff < 7) return '${days[d.weekday - 1]} $time';
  if (d.year == n.year) return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}
