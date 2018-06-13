//var DogeToken = artifacts.require("./token/DogeToken.sol");

// Token holder 1
// Private key in doge format: co6nPnPXdJQRxAQbeeUo3SQn5PkGGrEqP6a4K1QCmAkXNsBWFZEk
// Private Key in eth format: f968fec769bdd389e33755d6b8a704c04e3ab958f99cc6a8b2bcf467807f9634
// Eth Address: d2394f3fad76167e7583a876c292c86ed10305da

module.exports = async function(DogeToken, web3, command, callback) {
  var tokenHolderAddress = "0xd2394f3fad76167e7583a876c292c86ed10305da";      
  var tokenHolderPrivateKey = "0xf968fec769bdd389e33755d6b8a704c04e3ab958f99cc6a8b2bcf467807f9634";
  var tokenHolderAddress2 = "0xd2394f3fad76167e7583a876c292c86ed10305db";
  var valueToTransfer = 300000000;

  var dt = await DogeToken.deployed();

  // Make sure tokenHolderAddress has some eth to pay for txs
  var tokenHolderAddressEthBalance = await web3.eth.getBalance(tokenHolderAddress);     
  console.log("tokenHolderAddress eth balance : " + tokenHolderAddressEthBalance.toNumber());
  if (tokenHolderAddressEthBalance.toNumber() == 0) {
    console.log("no eth balance, sending some eth...")
    var fromAddress = web3.eth.accounts[0];  
    await web3.eth.sendTransaction({from: fromAddress, to: tokenHolderAddress, value: 1000000000000000000});
    tokenHolderAddressEthBalance = await web3.eth.getBalance(tokenHolderAddress);     
    console.log("tokenHolderAddress eth balance : " + tokenHolderAddressEthBalance.toNumber());  
  }

  // Print DogeToken balances before transfer
  var tokenHolderAddressDogeTokenBalance = await dt.balanceOf.call(tokenHolderAddress);     
  console.log("tokenHolderAddress DogeToken balance : " + tokenHolderAddressDogeTokenBalance.toNumber());     
  if (command == "transfer") {
    var tokenHolderAddress2DogeTokenBalance = await dt.balanceOf.call(tokenHolderAddress2);     
    console.log("tokenHolderAddress2 DogeToken balance : " + tokenHolderAddress2DogeTokenBalance.toNumber());         
  }

  // Add tokenHolderPrivateKey to eth node (if already added, this makes no harm)
  await web3.personal.importRawKey(tokenHolderPrivateKey, "");
  await web3.personal.unlockAccount(tokenHolderAddress, "", 0);    

  if (command == "transfer") {
    // Do transfer  
    console.log("Transfering " + valueToTransfer + " DogeTokens from " + tokenHolderAddress + " to " + tokenHolderAddress2);     
    await dt.transfer(tokenHolderAddress2, valueToTransfer, {from: tokenHolderAddress});     
  } else if (command == "unlock") {
    // Do unlock
    var minUnlockValue = await dt.MIN_UNLOCK_VALUE();
    minUnlockValue = minUnlockValue.toNumber();
    const operatorsLength = await dt.getOperatorsLength();
    var valueTransferred = 0;
    for (var i = 0; i < operatorsLength; i++) {      
      let operatorKey = await dt.operatorKeys(i);
      if (operatorKey[1] == false) {
        // not deleted
        let operatorPublicKeyHash = operatorKey[0];
        let operator = await dt.operators(operatorPublicKeyHash);
        var dogeAvailableBalance = operator[1].toNumber();
        if (dogeAvailableBalance >= minUnlockValue) {
          // dogeAvailableBalance >= MIN_UNLOCK_VALUE  
          var valueToTransferWithThisOperator = Math.min(valueToTransfer - valueTransferred, dogeAvailableBalance);
          console.log("Unlocking " + valueToTransferWithThisOperator + " DogeTokens using operator " + operatorPublicKeyHash);     
          await dt.doUnlock("ncbC7ZY1K9EcMVjvwbgSBWKQ4bwDWS4d5P", valueToTransfer, operatorPublicKeyHash, {from: tokenHolderAddress});
          // assert.equal(operator[1].toString(10), 0, 'operator dogeAvailableBalance is not the expected one');
          valueTransferred += valueToTransferWithThisOperator;
        }
      }
      if (valueTransferred == valueToTransfer) {
        break;
      }
    }
    console.log("Total unlocked " + valueTransferred + " DogeTokens from " + tokenHolderAddress);     
  }

  // Print DogeToken balances after transfer
  tokenHolderAddressDogeTokenBalance = await dt.balanceOf.call(tokenHolderAddress);     
  console.log("tokenHolderAddress DogeToken balance : " + tokenHolderAddressDogeTokenBalance.toNumber());     
  if (command == "transfer") {
    tokenHolderAddress2DogeTokenBalance = await dt.balanceOf.call(tokenHolderAddress2);     
    console.log("tokenHolderAddress2 DogeToken balance : " + tokenHolderAddress2DogeTokenBalance.toNumber());     
  }

}

