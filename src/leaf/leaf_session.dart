import 'package:dartcarwings/dartcarwings.dart';
import 'package:logging/logging.dart';

import 'carwings_wrapper.dart';
import 'leaf_vehicle.dart';
import 'nissan_connect_na_wrapper.dart';
import 'nissan_connect_wrapper.dart';

final Logger _log = Logger('LeafSession');

enum LeafType {
  newerThanMay2019,
  olderCanada,
  olderUsa,
  olderEurope,
  olderAustralia,
  olderJapan,
}

LeafSession createLeafSession(LeafType leafType, String username, String password) {
  switch (leafType) {
    case LeafType.newerThanMay2019:
      return NissanConnectSessionWrapper(username, password);
    case LeafType.olderCanada:
      return NissanConnectNASessionWrapper('CA', username, password);
    case LeafType.olderUsa:
      return NissanConnectNASessionWrapper('US', username, password);
    case LeafType.olderEurope:
      return CarwingsWrapper(CarwingsRegion.Europe, username, password);
    case LeafType.olderJapan:
      return CarwingsWrapper(CarwingsRegion.Japan, username, password);
    case LeafType.olderAustralia:
      return CarwingsWrapper(CarwingsRegion.Australia, username, password);
    default:
      throw ArgumentError.value(leafType, 'leafType', 'this LeafType is not supported yet.');
  }
}

abstract class LeafSessionInternal extends LeafSession {
  LeafSessionInternal(this.username, this.password);

  final String username;
  final String password;

  List<VehicleInternal> _lastKnownVehicles = <VehicleInternal>[];

  @override
  List<Vehicle> get vehicles => _lastKnownVehicles;

  void setVehicles(List<VehicleInternal> newVehicles) {
    // keep the last states
    for (final VehicleInternal lastKnownVehicle in _lastKnownVehicles) {
      final VehicleInternal? matchingVehicle =
          newVehicles.firstWhereOrNull((vehicle) => vehicle.vin == lastKnownVehicle.vin);
      matchingVehicle?.setLastKnownStatus(lastKnownVehicle);
    }

    _lastKnownVehicles = newVehicles;
  }

  @override
  Map<String, String> getAllLastKnownStatus() =>
      _lastKnownVehicles.fold(<String, String>{}, (allLastKnownStatus, vehicle) {
        allLastKnownStatus.addAll(vehicle.getLastKnownStatus());
        return allLastKnownStatus;
      });
}

typedef ExecutionErrorCallback = void Function(String vin);
typedef ExecutableVehicleActionHandler<T> = Future<T> Function(Vehicle vehicle);
typedef SyncExecutableVehicleActionHandler<T> = T Function(Vehicle vehicle);

abstract class LeafSession {
  LeafSession({this.onExecutionError});

  ExecutionErrorCallback? onExecutionError;

  List<Vehicle> get vehicles;

  Vehicle _getVehicle(String vin) =>
      vehicles.firstWhere((vehicle) => vehicle.vin == vin,
          orElse: () => throw Exception('Vehicle $vin not found.'));

  Future<void> login();

  Map<String, String> getAllLastKnownStatus();

  T? executeSync<T>(SyncExecutableVehicleActionHandler<T> executable, String vin) {
    try {
      return executable(_getVehicle(vin));
    } catch (e, stackTrace) {
      _logException(e, stackTrace);
    }
    return null;
  }

  Future<void> executeCommandWithRetry(
      ExecutableVehicleActionHandler<bool> executable, String vin, int commandAttempts) async {
    bool anyCommandSucceeded = false;
    for (int attempts = 0; attempts < commandAttempts; ++attempts) {
      try {
        anyCommandSucceeded |= await _executeWithRetry((vehicle) async => await executable(vehicle), vin);
      } catch (e, stackTrace) {
        _logException(e, stackTrace);
      }
    }

    if (!anyCommandSucceeded && onExecutionError != null) {
      onExecutionError!(vin);
    }
  }

  Future<T?> executeWithRetry<T>(ExecutableVehicleActionHandler<T> executable, String vin) async {
    try {
      return await _executeWithRetry(executable, vin);
    } catch (e, stackTrace) {
      _logException(e, stackTrace);
      if (onExecutionError != null) {
        onExecutionError!(vin);
      }
    }
    return null;
  }

  Future<T> _executeWithRetry<T>(ExecutableVehicleActionHandler<T> executable, String vin) async {
    int attempts = 0;
    while (attempts < 2) {
      if (attempts > 0) {
        try {
          _log.finer('Force a login before retrying failed execution.');
          await login();
        } catch (e, stackTrace) {
          _logException(e, stackTrace);
        }
      }

      try {
        return await _execute(executable, vin);
      } catch (e, stackTrace) {
        _logException(e, stackTrace);
      }
      ++attempts;
    }
    throw Exception('Execution failed.');
  }

  Future<T> _execute<T>(ExecutableVehicleActionHandler<T> executable, String vin) {
    _log.finest('Executing');
    return executable(_getVehicle(vin));
  }

  void _logException(dynamic e, StackTrace stackTrace) {
    _log.fine(e);
    _log.finer(stackTrace);
  }
}

/// Extension method to add firstWhereOrNull for convenience (or use package:collection)
extension IterableExtensions<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (var element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}