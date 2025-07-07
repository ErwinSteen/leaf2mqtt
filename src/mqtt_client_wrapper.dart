import 'dart:io';

import 'package:logging/logging.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

final Logger _log = Logger('MqttClientWrapper');

typedef PayloadReceivedHandler = void Function(String payload);

class MqttClientWrapper {
  late final MqttServerClient _mqttClient;
  late final String _baseTopic;
  final AsciiPayloadConverter _converter = AsciiPayloadConverter();

  final Map<String, List<PayloadReceivedHandler>> _payloadReceivedHandlers = <String, List<PayloadReceivedHandler>>{};

  ConnectCallback? onConnected;
  DisconnectCallback? onDisconnected;

  MqttClientWrapper() {
    final Map<String, String> envVars = Platform.environment;

    final String mqttHost = envVars['MQTT_HOST'] ?? '127.0.0.1';
    final int mqttPort = int.tryParse(envVars['MQTT_PORT'] ?? '1883') ?? 1883;
    _baseTopic = envVars['MQTT_BASE_TOPIC'] ?? 'leaf';

    _log.info('Creating MQTT client with $mqttHost:$mqttPort listening on $_baseTopic.');
    _mqttClient = MqttServerClient.withPort(mqttHost, 'leaf2mqtt', mqttPort);
    _mqttClient.keepAlivePeriod = 60;
  }

  Future<void> connectWithRetry(String? mqttUser, String? mqttPassword) async {
    _log.info('Connecting...');
    _mqttClient.onConnected = onConnected;

    // Set to null to prevent multiple connectWithRetry
    // calls since onDisconnected is called when a connection fails.
    _mqttClient.onDisconnected = null;

    bool connected = false;
    while (!connected) {
      try {
        final MqttClientConnectionStatus connectionStatus = await _mqttClient.connect(mqttUser, mqttPassword);
        _log.info('Mqtt connection code: ${connectionStatus.returnCode}');
        connected = connectionStatus.returnCode == MqttConnectReturnCode.connectionAccepted;
      } catch (e, stackTrace) {
        _log.warning('An error occurred while connecting to MQTT broker. Retrying in 5 seconds.');
        _log.info(e);
        _log.finest(stackTrace);
      }

      if (connected) {
        _mqttClient.onDisconnected = () => connectWithRetry(mqttUser, mqttPassword);
      } else {
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
  }

  void subscribeToCommandTopic() {
    _log.info('Subscribing to command topics');
    _mqttClient.subscribe('$_baseTopic/command/#', MqttQos.exactlyOnce);
    _mqttClient.subscribe('$_baseTopic/+/command/#', MqttQos.exactlyOnce);
    _mqttClient.updates.listen(_receiveData);
  }

  void subscribeTopic(String topic, PayloadReceivedHandler handler) {
    _log.fine('Subscribing to $topic');
    _payloadReceivedHandlers.update(
      '$_baseTopic/$topic',
      (List<PayloadReceivedHandler> handlers) {
        handlers.add(handler);
        return handlers;
      },
      ifAbsent: () => <PayloadReceivedHandler>[handler],
    );
  }

  void publishMessage(String topic, String value) {
    if (topic.isNotEmpty && value.isNotEmpty) {
      _log.finest('Publishing message $topic $value');
      try {
        _mqttClient.publishMessage(
          '$_baseTopic/$topic',
          MqttQos.atLeastOnce,
          _converter.convertToBytes(value),
          retain: true,
        );
      } on ConnectionException {
        _log.finest('Connection error while publishing message');
        // does not matter, we will send back latest states on reconnect.
      } catch (e, stackTrace) {
        _log.fine('Exception when publishing message: $e');
        _log.finer(stackTrace);
      }
    }
  }

  void _receiveData(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final MqttReceivedMessage<MqttMessage> message in messages) {
      final MqttPublishMessage pubMessage = message.payload as MqttPublishMessage;
      final String payload =
          MqttPublishPayload.bytesToStringAsString(pubMessage.payload.message).toLowerCase();

      _log.finer('Received data: ${message.topic} $payload');
      final List<PayloadReceivedHandler> handlers =
          _payloadReceivedHandlers[message.topic] ?? <PayloadReceivedHandler>[];
      for (final PayloadReceivedHandler handler in handlers) {
        handler(payload);
      }
    }
  }
}