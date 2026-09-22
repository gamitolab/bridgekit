import type { BridgeContract } from '@gamitolab/bridgekit/contract';
import { defineContract, t } from '@gamitolab/bridgekit/contract';

export const SchemaKindsFixture: BridgeContract<unknown> = defineContract('compile.schema-kinds', {
  methods: {
    getStatus: t.query(t.enum({ Ready: 0, Busy: 1 })),
    getStatusSync: t.querySync(t.enum({ Ready: 0, Busy: 1 })),
  },
});
