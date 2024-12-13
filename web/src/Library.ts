import _ from "lodash";

class Library {
  clear() {}
}

const library = _.memoize(() => new Library());
export default library;
