import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/commands/central_sync_transport.dart';
import 'package:material_lab/core/commands/command_contract.dart';
import 'package:material_lab/core/commands/command_transport.dart';

void main() {
  test('unconfigured command transport leaves requests retryable', () async {
    final envelope = CommandEnvelope.create(
      organizationId: 'org',
      commandType: CommandTypes.domainCommit,
      entityId: 'draft',
      expectedVersion: 0,
      payload: {'writes': []},
      deviceId: 'device',
    );
    final result = await const UnconfiguredCommandTransport().submit(envelope);
    expect(result.isApproved, isFalse);
    expect(result.failure?.code, CommandErrorCodes.unavailable);
    expect(result.operationId, envelope.operationId);
  });
  test('unconfigured reader refuses to present a successful archive', () async {
    await expectLater(
      const UnconfiguredCentralSyncReader().call({'mode': 'beginSnapshot'}),
      throwsStateError,
    );
  });
}
