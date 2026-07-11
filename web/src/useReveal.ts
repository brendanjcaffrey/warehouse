import { useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { useSetAtom } from "jotai";
import { RevealTarget, revealTargetAtom, searchAtom } from "./State";

// navigates to a view and asks it to reveal a track: select it, scroll to it and
// highlight it. the search is cleared first so an active filter can't hide the
// track we're jumping to. shared by the track menu and the now playing bar
export function useReveal() {
  const navigate = useNavigate();
  const setReveal = useSetAtom(revealTargetAtom);
  const setSearch = useSetAtom(searchAtom);

  return useCallback(
    (target: RevealTarget, path: string) => {
      setSearch("");
      setReveal(target);
      navigate(path);
    },
    [navigate, setReveal, setSearch]
  );
}
