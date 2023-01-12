const fs = require("fs");
const glob = require("glob");

/**
 * This script is used to prepare the solidity files for use with `forge doc`
 * Seaport handles decoding structs from calldata itself, but solc will use its default decoding
 * if they are given names. Thus, to comply with natspec, we use  @custom tags to specify "unnamed" params
 * and their names. This is not compatible with forge doc, so we must turn them back into normal @param tags
 * before generating documentation.
 */

glob("contracts/**/*.sol", {}, (er, files) => {
  files.forEach((file) => {
    let content = fs.readFileSync(file, "utf-8");

    // Restore normal @param tags
    content = content.replace(/@custom:param/g, "@param");
    // Replace @custom:name tags with the name of the param in the correct location
    content = content.replace(
      /(,|\))\s*\/\*\*\s*\*?\s*@custom:name\s*( [^*]*)\s*\*\/\s*/g,
      "$2$1"
    );

    // once we overwrite the files, we can call forge doc to generate documentation complete with descriptions for
    // "unnamed" variables
    fs.writeFileSync(file, content, "utf-8");
  });
});
