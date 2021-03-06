
# data will need to be an unmarkedMultFrame
gmultmix <- function(lambdaformula, phiformula, pformula, data, 
    mixture=c('P', 'NB'), K, starts, method = "BFGS", control = list(), se = TRUE)
{
if(!is(data, "unmarkedFrameGMM"))
    stop("Data is not of class unmarkedFrameGMM.")

mixture <- match.arg(mixture)

formlist <- list(lambdaformula = lambdaformula, phiformula = phiformula, 
    pformula = pformula)
form <- as.formula(paste(unlist(formlist), collapse=" "))
D <- unmarked:::getDesign(data, formula = form)

Xlam <- D$Xlam
Xphi <- D$Xphi 
Xdet <- D$Xdet
y <- D$y  # MxJT 

Xlam.offset <- D$X.offset
Xphi.offset <- D$Xphi.offset
Xdet.offset <- D$Xdet.offset
if(is.null(Xlam.offset)) Xlam.offset <- rep(0, nrow(Xlam))
if(is.null(Xphi.offset)) Xphi.offset <- rep(0, nrow(Xphi))
if(is.null(Xdet.offset)) Xdet.offset <- rep(0, nrow(Xdet))

if(missing(K) || is.null(K)) K <- max(y, na.rm=TRUE) + 20
k <- 0:K
lk <- length(k)
M <- nrow(y)  
T <- data@numPrimary
R <- ncol(y)
J <- R / T

y <- array(y, c(M, J, T))
y <- aperm(y, c(1,3,2))
yt <- apply(y, 1:2, function(x) {
    if(all(is.na(x))) 
        return(NA)
    else return(sum(x, na.rm=TRUE))
    })


piFun <- data@piFun

lamPars <- colnames(Xlam)
phiPars <- colnames(Xphi)
detPars <- colnames(Xdet)
nLP <- ncol(Xlam)
nPP <- ncol(Xphi)
nDP <- ncol(Xdet)
nP <- nLP + nPP + nDP + ifelse(mixture=='NB', 1, 0)

cp <- array(as.numeric(NA), c(M, T, J+1))
g <- matrix(as.numeric(NA), M, lk)

lfac.k <- lgamma(k+1)
kmyt <- array(NA, c(M, T, lk))
lfac.kmyt <- array(0, c(M, T, lk))
fin <- matrix(NA, M, lk)
naflag <- array(NA, c(M, T, J))
for(i in 1:M) {
    fin[i, ] <- k - max(yt[i,], na.rm=TRUE) >= 0
    for(t in 1:T) {
        naflag[i,t,] <- is.na(y[i,t,])
        if(!all(naflag[i,t,])) {
            kmyt[i,t,] <- k - yt[i,t]
            lfac.kmyt[i, t, fin[i,]] <- lgamma(kmyt[i, t, fin[i,]] + 1)
            }
        }
    }
    
## NA handling
# Sites w/ missing siteCovs should be removed beforehand
# Sites w/ some missing yearlySiteCovs shoul be retained but      

nll <- function(pars) {
    lambda <- exp(Xlam %*% pars[1:nLP] + Xlam.offset) 
    phi <- drop(plogis(Xphi %*% pars[(nLP+1):(nLP+nPP)] + Xphi.offset))
    p <- plogis(Xdet %*% pars[(nLP+nPP+1):(nLP+nPP+nDP)] + Xdet.offset)

    phi.mat <- matrix(phi, M, T, byrow=TRUE)
    phi <- as.numeric(phi.mat)
    
    p <- matrix(p, nrow=M, byrow=TRUE)
    p <- array(p, c(M, J, T))
    p <- aperm(p, c(1,3,2))     
    cp <- array(as.numeric(NA), c(M, T, J+1))
    
    for(t in 1:T) cp[,t,1:J] <- do.call(piFun, list(p[,t,]))
    cp[,,1:J] <- cp[,,1:J] * phi
    cp[,,J+1] <- 1 - apply(cp[,,1:J], 1:2, sum, na.rm=TRUE) # is na.rm=T valid?
    
    switch(mixture, 
        P = f <- sapply(k, function(x) dpois(x, lambda)),
        NB = f <- sapply(k, function(x) dnbinom(x, mu=lambda, 
            size=exp(pars[nP]))))
    for(i in 1:M) {
        A <- matrix(0, lk, T)
        for(t in 1:T) {
            if(all(naflag[i,t,])) 
                A[,t] <- 0 
            else                 
                A[, t] <- lfac.k - lfac.kmyt[i, t,] + 
                    sum(y[i, t, !naflag[i,t,]] * 
                    log(cp[i, t, which(!naflag[i,t,])])) + 
                    kmyt[i, t,] * log(cp[i, t, J+1])
            }
        g[i,] <- exp(rowSums(A))
        }
    f[!fin] <- g[!fin] <- 0
    ll <- rowSums(f*g)
    -sum(log(ll))
    }
    
if(missing(starts)) starts <- rep(0, nP)
fm <- optim(starts, nll, method = method, hessian = se, control = control)
opt <- fm
if(se) {
		covMat <- tryCatch(solve(fm$hessian), error=function(x) 
        simpleError("Hessian is singular. Try using fewer covariates."))
    if(identical(class(covMat)[1], "simpleError")) {
        warning(covMat$message)
        covMat <- matrix(NA, nP, nP)
        }
    } else covMat <- matrix(NA, nP, nP)
ests <- fm$par
fmAIC <- 2 * fm$value + 2 * nP

if(identical(mixture,"NB")) nbParm <- "alpha"
	else nbParm <- character(0)

names(ests) <- c(lamPars, phiPars, detPars, nbParm)

lamEstimates <- unmarkedEstimate(name = "Abundance", short.name = "lambda",
    estimates = ests[1:nLP],
    covMat = as.matrix(covMat[1:nLP, 1:nLP]), invlink = "exp",
    invlinkGrad = "exp")
phiEstimates <- unmarkedEstimate(name = "Availability", short.name = "phi",
    estimates = ests[(nLP+1):(nLP+nPP)],
    covMat = as.matrix(covMat[(nLP+1):(nLP+nPP), (nLP+1):(nLP+nPP)]), 
        invlink = "logistic",
    invlinkGrad = "logistic.grad")
detEstimates <- unmarkedEstimate(name = "Detection", short.name = "p",
    estimates = ests[(nLP+nPP+1):(nLP+nPP+nDP)],
    covMat = as.matrix(
        covMat[(nLP+nPP+1):(nLP+nPP+nDP), (nLP+nPP+1):(nLP+nPP+nDP)]), 
    invlink = "logistic", invlinkGrad = "logistic.grad")
estimateList <- unmarked:::unmarkedEstimateList(list(lambda=lamEstimates,
    phi=phiEstimates, det=detEstimates))

if(identical(mixture,"NB"))
		estimateList@estimates$alpha <- unmarkedEstimate(name = "Dispersion",
        short.name = "alpha", estimates = ests[nP],
        covMat = as.matrix(covMat[nP, nP]), invlink = "exp",
        invlinkGrad = "exp")

umfit <- new("unmarkedFitGMM", fitType = "gmn", 
    call = match.call(), formula = form, formlist = formlist,    
    data = data, estimates = estimateList, sitesRemoved = D$removed.sites, 
    AIC = fmAIC, opt = opt, negLogLike = fm$value, nllFun = nll,
    mixture=mixture, K=K)

return(umfit)
}




