import { useState } from "react";
import { OverlayTrigger, Tooltip } from "react-bootstrap";
import { List } from "react-bootstrap-icons";
import IconButton from "./IconButton";
import QueuePanel from "./QueuePanel";

// the queue button in the right icon cluster; opens a panel showing the play
// history, the current track and what's up next
function Queue() {
  const [show, setShow] = useState(false);

  return (
    <>
      <OverlayTrigger placement="bottom" overlay={<Tooltip>Queue</Tooltip>}>
        <IconButton aria-label="queue" onClick={() => setShow(true)}>
          <List size={26} />
        </IconButton>
      </OverlayTrigger>
      <QueuePanel show={show} onHide={() => setShow(false)} />
    </>
  );
}

export default Queue;
