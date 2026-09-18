import 'api.dart';

/// Code of the catch-all type; its label comes from the report's title.
const kOtherIncident = 'lainnya';

/// The backend's incident types ([{code, label, description}]), fetched once.
Future<List<Json>>? _typesFuture;

Future<List<Json>> loadIncidentTypes() {
  final future = _typesFuture ??= Api.instance.get('/incident-types').then((v) => (v as List).cast<Json>());
  // Don't cache a failure (e.g. offline): the next caller should retry.
  future.catchError((_) {
    _typesFuture = null;
    return <Json>[];
  });
  return future;
}
