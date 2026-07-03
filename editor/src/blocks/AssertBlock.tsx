import type { Block } from "../domain/types";
import { useStore, selectCurrentFlow } from "../state/store";
import { PredicateEditor } from "./PredicateEditor";

interface Props {
  block: Block;
}

export function AssertBlock({ block }: Props) {
  const flow = useStore(selectCurrentFlow);
  const updatePredicate = useStore((s) => s.updatePredicate);
  if (!flow || !block.predicate) return null;

  return (
    <div
      className={`logic-wrapper logic-assert status-${block.meta.status}`}
      data-testid={`assert-${block.id}`}
      data-block-id={block.id}
    >
      <div className="logic-header">
        <span className="drag-handle" title="Arrastrar para reordenar" aria-hidden>⋮⋮</span>
        <span className="logic-keyword assert-keyword">assert</span>
        <PredicateEditor
          value={block.predicate}
          onChange={(p) => updatePredicate(flow.id, block.id, p)}
        />
      </div>
    </div>
  );
}
