var DogeRelayForTests = artifacts.require("./DogeRelayForTests.sol");
var DogeToken = artifacts.require("./token/DogeToken.sol");

module.exports = function(callback) {
  var dr;
  DogeRelayForTests.deployed().then(function(instance) {      
    dr = instance;
    return dr.getBestBlockHash.call(); 
  }).then(function(result) {
    console.log("Best block hash : " + result.toString(16));
    return dr.getBestBlockHeight.call(); 
  }).then(function(result) {
    console.log("Best block height : " + result.toString(10));
    callback();
  }).catch(function(e) {
    // There was an error! Handle it.
    console.log(e);
    callback(e);
  });
}