functions {

    // function equivalent to %in% on R from https://discourse.mc-stan.org/t/stan-equivalent-of-rs-in-function/3849
    int r_in(int pos,int[] pos_var) {
   
        for (p in 1:(size(pos_var))) {
            if (pos_var[p]==pos) {
                // can return immediately, as soon as find a match
                return 1;
            }
        }
        return 0;
    }

    /*
     * returns multiplier on the rows of the contact matrix over time for one country
     */
    matrix country_impact(
        vector beta,
        real upswing_rdeff_local,
        int N2,
        int A,
        int COVARIATES_N,
        matrix[] covariates_local
        )
    {

        // scaling of contacts after intervention effect on day t in location m
        matrix[N2,A] impact_intv;
    
        // define multipliers for contacts in each location
        impact_intv = rep_matrix( 0, N2, A);
        //for(i in 1:COVARIATES_N)
        //{
        impact_intv += beta[1] * covariates_local[1] + (beta[2] + upswing_rdeff_local) * covariates_local[2];
        //}
        impact_intv = exp( impact_intv );
        
        return (impact_intv);
    }
  
    matrix country_EcasesByAge(// parameters
        real R0_local,
        real e_cases_N0_local,
        row_vector log_relsusceptibility_age,
        row_vector log_reltransmissibility_age,
        matrix impact_intv,
        // data
        int N0,
        int N2,
        int A,
        int SI_CUT,
        int[] wkend_idx_local,
        real avg_cntct_local,
        matrix cntct_weekends_mean_local,
        matrix cntct_weekdays_mean_local,
        row_vector rev_serial_interval,
        row_vector popByAge_abs_local,
        int N_init_A,
        int[] init_A
        )
    {
        real zero;
        real rho0;
        real N_init_A_real;
        row_vector[A] tmp_row_vector_A;
        matrix[N2,A] E_casesByAge;
        
        zero = 0.0;
        
        // probability of infection given contact in location m
        rho0 = R0_local / avg_cntct_local;
          
        // expected new cases by calendar day, age, and location under self-renewal model
        // and a container to store the precomputed cases by age
        E_casesByAge = rep_matrix( zero, N2, A );
          
        // init expected cases by age and location in first N0 days
        N_init_A_real= N_init_A*1.;
        E_casesByAge[1:N0, init_A] = rep_matrix( e_cases_N0_local/N_init_A_real, N0, N_init_A);
                
        // calculate expected cases by age and country under self-renewal model after first N0 days
        // and adjusted for saturation
        for (t in (N0+1):N2)
        {
            int start_idx_rev_serial = SI_CUT-t+2;
            int start_idx_E_casesByAge = t-SI_CUT;
            row_vector[A] prop_susceptibleByAge = rep_row_vector(1.0, A) - (rep_row_vector(1.0, t-1) * E_casesByAge[1:(t-1),:] ./ popByAge_abs_local);
            if(start_idx_rev_serial < 1)
            {
                start_idx_rev_serial = 1;
            }
            if(start_idx_E_casesByAge < 1)
            {
                start_idx_E_casesByAge = 1;
            }
            // TODO can t we vectorise this?
            for(a in 1:A)
            {
                if(prop_susceptibleByAge[a] < 0)
                { // account for values of Ecases > pop at initalization
                    prop_susceptibleByAge[a] = 0;
                }
            }
            
            tmp_row_vector_A = rev_serial_interval[start_idx_rev_serial:SI_CUT] * E_casesByAge[start_idx_E_casesByAge:(t-1)];
            tmp_row_vector_A .*= impact_intv[t,];
            tmp_row_vector_A .*= ( rho0 * exp(log_reltransmissibility_age) );
            if(r_in(t, wkend_idx_local) == 1)
            {
                E_casesByAge[t] = tmp_row_vector_A * cntct_weekends_mean_local;
            }
            else
            {
                E_casesByAge[t] = tmp_row_vector_A * cntct_weekdays_mean_local;
            }
            E_casesByAge[t] .*= prop_susceptibleByAge;
            E_casesByAge[t] .*= exp(log_relsusceptibility_age);
            E_casesByAge[t] .*= impact_intv[t,];
        }
        return(E_casesByAge);
    }
  
    matrix country_Rta(// parameters
        real rho0_local,
        row_vector log_relsusceptibility_age,
        row_vector log_reltransmissibility_age,
        matrix impact_intv,
        matrix E_casesByAge_local,
        // data
        int N2,
        int A,
        int[] wkend_idx_local,
        matrix cntct_weekends_mean_local,
        matrix cntct_weekdays_mean_local,
        row_vector popByAge_abs_local
        )
    {
        matrix[N2,A] RtByAge;
        matrix[N2,A] prop_susceptibleByAge;
        
        for(a in 1:A)
        {
            prop_susceptibleByAge[1,a] = 0;
            prop_susceptibleByAge[2:N2,a] = cumulative_sum( E_casesByAge_local[1:(N2-1),a] ) / popByAge_abs_local[a];
            for( t in 1:N2)
            {
                if( prop_susceptibleByAge[t,a]>1 )
                {
                    prop_susceptibleByAge[t,a]= 1.;
                }
            }
        }
        prop_susceptibleByAge = rep_matrix(1.0, N2, A) - prop_susceptibleByAge;
        RtByAge = prop_susceptibleByAge;
        RtByAge .*= rep_matrix( exp(log_relsusceptibility_age), N2);
        RtByAge *= rho0_local;
        for(t in 1:N2)
        {
            if(r_in(t, wkend_idx_local) == 1)
            {
                RtByAge[t,:] = ( (impact_intv[t,:] .* RtByAge[t,:]) * (cntct_weekends_mean_local') ) .* impact_intv[t,:];
            }
            else
            {
                RtByAge[t,:] = ( (impact_intv[t,:] .* RtByAge[t,:]) * (cntct_weekdays_mean_local') ) .* impact_intv[t,:];
            }
        }
        return(RtByAge);
    }
  
  
    matrix country_lambdaByAge(// parameters
        real rho0_local,
        row_vector log_relsusceptibility_age,
        row_vector log_reltransmissibility_age,
        matrix impact_intv,
        matrix E_casesByAge,
        // data
        int N0,
        int N2,
        int A,
        int SI_CUT,
        int[] wkend_idx_local,
        matrix cntct_weekends_mean_local,
        matrix cntct_weekdays_mean_local,
        row_vector rev_serial_interval
        )
    {
        row_vector[A] tmp_row_vector_A;
        matrix[A,A] tmp_lambda;
        matrix[N2, A] lambdaByAge;
              
        // calculate expected cases by age and country under self-renewal model after first N0 days
        // and adjusted for saturation
        lambdaByAge[1:N0, 1:A] = rep_matrix(0.,N0,A);
        for (t in (N0+1):N2)
        {
            int start_idx_rev_serial = SI_CUT-t+2;
            int start_idx_E_casesByAge = t-SI_CUT;
        
            if(start_idx_rev_serial < 1) {
                start_idx_rev_serial = 1;
            }
            if(start_idx_E_casesByAge < 1) {
                start_idx_E_casesByAge = 1;
            }
            tmp_row_vector_A = rev_serial_interval[start_idx_rev_serial:SI_CUT] * E_casesByAge[start_idx_E_casesByAge:(t-1)];
            tmp_row_vector_A .*= impact_intv[t,];
            tmp_row_vector_A .*= ( rho0_local * exp(log_reltransmissibility_age) );
            if(r_in(t, wkend_idx_local) == 1){
              lambdaByAge[t] = tmp_row_vector_A * cntct_weekends_mean_local;
            }else{
              lambdaByAge[t] = tmp_row_vector_A * cntct_weekdays_mean_local;
            }
            lambdaByAge[t] .*= exp(log_relsusceptibility_age);
            lambdaByAge[t] .*= impact_intv[t,];
        }
        return(lambdaByAge);
    }
  
    matrix country_EflowsByHighDimAge_AggregateDays(// parameters
        real rho0_local,
        matrix impact_intv,
        matrix E_casesByAge,
        row_vector log_relsusceptibility_age,
        row_vector log_reltransmissibility_age,
        // data
        int A,
        int SI_CUT,
        int[] wkend_idx_local,
        matrix cntct_weekends_mean_local,
        matrix cntct_weekdays_mean_local,
        row_vector rev_serial_interval,
        row_vector popByAge_abs_local,
        int full_flows_Monday_idx_local,
        int n_days
        )
    {
        real zero;
        int start_idx_rev_serial;
        int start_idx_E_casesByAge;
        row_vector[A] tmp_row_vector_A;
        row_vector[A] prop_susceptibleByAge;
        matrix[A,A] tmp_flow;
        matrix[A,A] full_flow;
        
        zero = 0.0;
        full_flow = rep_matrix( zero, A, A);
            
        for (t in full_flows_Monday_idx_local:(full_flows_Monday_idx_local+n_days-1))
        {
            start_idx_rev_serial = SI_CUT-t+2;
            start_idx_E_casesByAge = t-SI_CUT;
            prop_susceptibleByAge = rep_row_vector(1.0, A) - (rep_row_vector(1.0, t-1) * E_casesByAge[1:(t-1),:] ./ popByAge_abs_local);
            
            if(start_idx_rev_serial < 1)
            {
                start_idx_rev_serial = 1;
            }
            if(start_idx_E_casesByAge < 1)
            {
                start_idx_E_casesByAge = 1;
            }
            // account for values of Ecases > pop at initalization
            for(a in 1:A)
            {
                if(prop_susceptibleByAge[a] < 0)
                {
                    prop_susceptibleByAge[a] = 0;
                }
            }
            tmp_row_vector_A = rev_serial_interval[start_idx_rev_serial:SI_CUT] * E_casesByAge[start_idx_E_casesByAge:(t-1)];
            tmp_row_vector_A .*= impact_intv[t,];
            tmp_row_vector_A .*= ( rho0_local * exp(log_reltransmissibility_age) );
            if(r_in(t, wkend_idx_local) == 1)
            {
                tmp_flow = rep_matrix(tmp_row_vector_A', A) .* cntct_weekends_mean_local;
            }
            else
            {
                tmp_flow = rep_matrix(tmp_row_vector_A', A) .* cntct_weekdays_mean_local;
            }
            tmp_flow .*= rep_matrix(exp(log_relsusceptibility_age),A);
            tmp_flow .*= rep_matrix(prop_susceptibleByAge,A);
            tmp_flow .*= rep_matrix(impact_intv[t,],A);
            full_flow += tmp_flow;
        }
        return(full_flow);
    }
    
    
    matrix[] country_EflowsByHighDimAge(// parameters
        real rho0_local,
        matrix impact_intv,
        matrix E_casesByAge,
        row_vector log_relsusceptibility_age,
        row_vector log_reltransmissibility_age,
        // data
        int A,
        int SI_CUT,
        int N_WEEKS_FULL_FLOWS_local,
        int[] wkend_idx_local,
        matrix cntct_weekends_mean_local,
        matrix cntct_weekdays_mean_local,
        row_vector rev_serial_interval,
        row_vector popByAge_abs_local,
        int[] full_flows_Monday_idx_local,
        int n_days
        )
    {
        matrix[A,A] full_flows[N_WEEKS_FULL_FLOWS_local];
        for (week in 1:N_WEEKS_FULL_FLOWS_local)
        {
            full_flows[week] =
                country_EflowsByHighDimAge_AggregateDays(
                    rho0_local,
                    impact_intv,
                    E_casesByAge,
                    log_relsusceptibility_age,
                    log_reltransmissibility_age,
                    A,
                    SI_CUT,
                    wkend_idx_local,
                    cntct_weekends_mean_local,
                    cntct_weekdays_mean_local,
                    rev_serial_interval,
                    popByAge_abs_local,
                    full_flows_Monday_idx_local[week],
                    n_days
                    );
        }
        return(full_flows);
    }
  
  
    matrix[] country_EflowsByLowDimAge(// parameters
          real rho0_local,
          matrix impact_intv,
          matrix E_casesByAge,
          row_vector log_relsusceptibility_age,
          row_vector log_reltransmissibility_age,
          // data
          int A,
          int A_REDUCED,
          int SI_CUT,
          int N_WEEKS_REDUCED_FLOWS_local,
          int[] wkend_idx_local,
          matrix cntct_weekends_mean_local,
          matrix cntct_weekdays_mean_local,
          row_vector rev_serial_interval,
          row_vector popByAge_abs_local,
          int[] reduced_age_bands_map,
          int[] reduced_flows_Monday_idx_local,
          int n_days
          )
    {
        matrix[A,A] full_flow;
        matrix[A_REDUCED,A_REDUCED] tmp_flow;
        matrix[A_REDUCED,A_REDUCED] reduced_flows[N_WEEKS_REDUCED_FLOWS_local];
                
        for (week in 1:N_WEEKS_REDUCED_FLOWS_local)
        {
            full_flow =
                country_EflowsByHighDimAge_AggregateDays(
                    rho0_local,
                    impact_intv,
                    E_casesByAge,
                    log_relsusceptibility_age,
                    log_reltransmissibility_age,
                    A,
                    SI_CUT,
                    wkend_idx_local,
                    cntct_weekends_mean_local,
                    cntct_weekdays_mean_local,
                    rev_serial_interval,
                    popByAge_abs_local,
                    reduced_flows_Monday_idx_local[week],
                    n_days
                    );
                    
            tmp_flow = rep_matrix(0.0, A_REDUCED, A_REDUCED);
            for (a in 1:A)
            {
                for (b in 1:A)
                {
                    tmp_flow[ reduced_age_bands_map[a], reduced_age_bands_map[b] ] += full_flow[a,b];
                }
            }
            
            reduced_flows[week] = tmp_flow;
        }
        return(reduced_flows);
    }
              
    matrix country_EdeathsByAge(// parameters
        matrix E_casesByAge_local,
        // data
        int N2,
        int A,
        row_vector rev_ifr_daysSinceInfection,
        row_vector log_ifr_age_base,
        real log_ifr_age_rnde_mid1_local,
        real log_ifr_age_rnde_mid2_local,
        real log_ifr_age_rnde_old_local
        )
    {
        real zero = 0.0;
        
        matrix[N2,A] E_deathsByAge = rep_matrix( zero, N2, A );
    
        // calculate expected deaths by age and country
        E_deathsByAge[1] = 1e-15 * E_casesByAge_local[1];
        for (t in 2:N2)
        {
            E_deathsByAge[t] = rev_ifr_daysSinceInfection[(N2-(t-1)+1):N2 ] * E_casesByAge_local[1:(t-1)];
        }
        E_deathsByAge .*= rep_matrix(exp(   log_ifr_age_base +
            append_col(append_col(append_col(
                rep_row_vector(0., 4),
                rep_row_vector(log_ifr_age_rnde_mid1_local, 6)),
                rep_row_vector(log_ifr_age_rnde_mid2_local, 4)),
                rep_row_vector(log_ifr_age_rnde_old_local, 4))
            ), N2);
        E_deathsByAge += 1e-15;
        return(E_deathsByAge);
    }

}

data {
  int<lower=1> M; // number of countries
  int<lower=1> N0; // number of initial days for which to estimate infections
  int<lower=1> N[M]; // days of observed data for country m. each entry must be <= N2
  int<lower=1> N2; // days of observed data + # of days to forecast
  int<lower=1> A; // number of age bands
  int<lower=1> SI_CUT; // number of days in serial interval to consider
  int<lower=1> COVARIATES_N; // number of days in serial interval to consider
  int WKEND_IDX_N[M]; // number of weekend indices in each location
  //	data
  real pop[M];
  matrix<lower=0, upper=1>[A,M] popByAge; // proportion of age bracket in population in location
  int epidemicStart[M];
  int deaths[N2, M]; // reported deaths -- the rows with i > N contain -1 and should be ignored
  int<lower=0> wkend_idx[N2,M]; //indices of 1:N2 that correspond to weekends in location m
  matrix[N2,A] covariates[M, COVARIATES_N]; // predictors for fsq contacts by age
  // data by age
  int<lower=0> M_AD; // number of countries with deaths by age data
  int<lower=1> dataByAgestart[M_AD]; // start of death by age data
  int deathsByAge[N2, A, M_AD]; // reported deaths by age -- the rows with i < dataByAgestart[M_AD] contain -1 and should be ignored + the column with j > A2[M_AD] contain -1 and should be ignored 
  int<lower=2> A_AD[M_AD]; // number of age groups reported 
  matrix[A, A] map_age[M_AD]; // map the age groups reported with 5 y age group -- the column with j > A2[M_AD] contain -1 and should be ignored
  int map_country[M,2]; // first column indicates if country has death by age date (1 if yes), 2 column map the country to M_AD
  //	priors
  matrix[A,A] cntct_weekdays_mean[M]; // mean of prior contact rates between age groups on weekdays
  matrix[A,A] cntct_weekends_mean[M]; // mean of prior contact rates between age groups on weekends
  real<upper=0> hyperpara_ifr_age_lnmu[A];  // hyper-parameters for probability of death in age band a log normal mean
  real<lower=0> hyperpara_ifr_age_lnsd[A];  // hyper-parameters for probability of death in age band a log normal sd
  row_vector[N2] rev_ifr_daysSinceInfection; // probability of death s days after infection in reverse order
  row_vector[SI_CUT] rev_serial_interval; // fixed pre-calculated serial interval using empirical data from Neil in reverse order
  int<lower=1>  N_init_A; // number of age bands with initial cases
  int<lower=1, upper=A> init_A[N_init_A]; // age band in which initial cases occur in the first N0 days
  //
  int<lower=1, upper=M> LOCATION_PROCESSING_IDX;
  int<lower=1> NMAX_WEEKS_FULL_FLOWS;
  int<lower=1, upper=NMAX_WEEKS_FULL_FLOWS> N_WEEKS_FULL_FLOWS[M];
  int<lower=-1, upper=N2-6> full_flows_Monday_idx[NMAX_WEEKS_FULL_FLOWS, M];
  int<lower=1, upper=A> A_REDUCED;
  int<lower=1> NMAX_WEEKS_REDUCED_FLOWS;
  int<lower=1, upper=NMAX_WEEKS_REDUCED_FLOWS> N_WEEKS_REDUCED_FLOWS[M];
  int<lower=1> n_days;
  int<lower=1, upper=A_REDUCED> reduced_age_bands_map[A];       // this is just {1,1,2,2,3,3,3,4,4,4,5,5,5,6,6,6,7,7}
  int<lower=-1, upper=N2-6> reduced_flows_Monday_idx[NMAX_WEEKS_REDUCED_FLOWS, M];
}

transformed data {
  vector<lower=0>[M] avg_cntct;
  vector[A] ones_vector_A = rep_vector(1.0, A);
  row_vector[A] ones_row_vector_A = rep_row_vector(1.0, A);
  int trans_deaths[M, N2]; // reported deaths -- the rows with i > N contain -1 and should be ignored
  matrix[M,A] popByAge_abs; 
  
  for( m in 1:M )
  {
    avg_cntct[m] = popByAge[:,m]' * ( cntct_weekdays_mean[m] * ones_vector_A ) * 5./7.;
    avg_cntct[m] += popByAge[:,m]' * ( cntct_weekends_mean[m] * ones_vector_A ) * 2./7.;

    trans_deaths[m,:] = deaths[:,m];
    
    popByAge_abs[m,:] = popByAge[:,m]' * pop[m]; // pop by age is a proportion of pop by age and pop is the absolute number 
  }
}

parameters {
  vector<lower=0>[M] R0; // R0
  real<lower=0> kappa; // variance parameter for country-specific R0  
  real<lower=0> tau; // prior rate of expected number of cases per day in the first N0 days, for each country
  real<lower=0> e_cases_N0[M]; // expected number of cases per day per age band in the first N0 days, for each country
  vector[COVARIATES_N] beta; // regression coefficients for time varying multipliers on contacts
  real upswing_rnde[M];
  real<lower=0> sd_upswing_rnde;
  real<lower=0> phi; // overdispersion parameter for likelihood model
  row_vector<upper=0>[A] log_ifr_age_base; // probability of death for age band a
  row_vector[M] log_ifr_age_rnde_mid1;
  row_vector[M] log_ifr_age_rnde_mid2;
  row_vector[M] log_ifr_age_rnde_old;
  real<lower=0> sd_log_ifr_age_rnde_mid1;
  real<lower=0> sd_log_ifr_age_rnde_mid2;
  real<lower=0> sd_log_ifr_age_rnde_old;
  row_vector[2] log_relsusceptibility_age_reduced;
  row_vector[2] log_reltransmissibility_age_reduced;
  real<lower=0> sd_log_reltransmissibility_age;
}

generated quantities
{
    real rho0;
    row_vector[A] log_relsusceptibility_age;
    row_vector[A] log_reltransmissibility_age;
    matrix[N2,A] impact_intv;
    matrix<lower=0>[N2,A] E_casesByAge;
    matrix<lower=0>[N2,A] E_deathsByAge;
    vector<lower=0>[N2] E_deaths;
    matrix<lower=0>[N2,A] RtByAge;
    matrix<lower=0>[N2,A] lambdaByAge;
    vector<lower=0>[N2] Rt;
    matrix[A_REDUCED,A_REDUCED] reduced_flows[ N_WEEKS_REDUCED_FLOWS[LOCATION_PROCESSING_IDX] ];
    matrix[A,A] full_flows[ N_WEEKS_FULL_FLOWS[LOCATION_PROCESSING_IDX] ];
    
    // matrix[ N_WEEKS_REDUCED_FLOWS[LOCATION_PROCESSING_IDX], A_REDUCED] differences;
        
    log_relsusceptibility_age = append_col( append_col( log_relsusceptibility_age_reduced[ { 1, 1, 1 } ],
        rep_row_vector(0., 10) ),
        log_relsusceptibility_age_reduced[ { 2,2,2,2,2 } ]
        );
    log_reltransmissibility_age = append_col( append_col( log_reltransmissibility_age_reduced[ { 1, 1, 1 } ],
        rep_row_vector(0., 10) ),
        log_reltransmissibility_age_reduced[ { 2,2,2,2,2 } ]
        );
        
    // generate expected cases by age + expected deaths by age
    {
        int m = LOCATION_PROCESSING_IDX;
        
        rho0 = R0[m] / avg_cntct[m];
                
        impact_intv =
            country_impact(beta,
                upswing_rnde[m],
                N2,
                A,
                COVARIATES_N,
                covariates[m]
                );
                        
        E_casesByAge =
            country_EcasesByAge(
                R0[m],
                e_cases_N0[m],
                log_relsusceptibility_age,
                log_reltransmissibility_age,
                impact_intv,
                N0,
                N2,
                A,
                SI_CUT,
                wkend_idx[1:WKEND_IDX_N[m],m],
                avg_cntct[m],
                cntct_weekends_mean[m],
                cntct_weekdays_mean[m],
                rev_serial_interval,
                popByAge_abs[m,],
                N_init_A,
                init_A
                );
                
        lambdaByAge =
            country_lambdaByAge(
                rho0,
                log_relsusceptibility_age,
                log_reltransmissibility_age,
                impact_intv,
                E_casesByAge,
                N0,
                N2,
                A,
                SI_CUT,
                wkend_idx[1:WKEND_IDX_N[m],m],
                cntct_weekends_mean[m],
                cntct_weekdays_mean[m],
                rev_serial_interval
                );
                
        reduced_flows =
            country_EflowsByLowDimAge(
                rho0,
                impact_intv,
                E_casesByAge,
                log_relsusceptibility_age,
                log_reltransmissibility_age,
                A,
                A_REDUCED,
                SI_CUT,
                N_WEEKS_REDUCED_FLOWS[m],
                wkend_idx[1:WKEND_IDX_N[m],m],
                cntct_weekends_mean[m],
                cntct_weekdays_mean[m],
                rev_serial_interval,
                popByAge_abs[m,],
                reduced_age_bands_map,
                reduced_flows_Monday_idx[1:N_WEEKS_REDUCED_FLOWS[m], m],
                n_days
                );
   
        full_flows =
            country_EflowsByHighDimAge(
                rho0,
                impact_intv,
                E_casesByAge,
                log_relsusceptibility_age,
                log_reltransmissibility_age,
                A,
                SI_CUT,
                N_WEEKS_FULL_FLOWS[m],
                wkend_idx[1:WKEND_IDX_N[m],m],
                cntct_weekends_mean[m],
                cntct_weekdays_mean[m],
                rev_serial_interval,
                popByAge_abs[m,],
                full_flows_Monday_idx[1:N_WEEKS_FULL_FLOWS[m], m],
                n_days
                );
                      
        E_deathsByAge =
            country_EdeathsByAge(
                E_casesByAge,
                N2,
                A,
                rev_ifr_daysSinceInfection,
                log_ifr_age_base,
                log_ifr_age_rnde_mid1[m],
                log_ifr_age_rnde_mid2[m],
                log_ifr_age_rnde_old[m]
                );
    
        // generate total expected deaths
        E_deaths = E_deathsByAge * ones_vector_A;
            
        // generate R_ta
        RtByAge =
            country_Rta(
                R0[m] / avg_cntct[m],
                log_relsusceptibility_age,
                log_reltransmissibility_age,
                impact_intv,
                E_casesByAge,
                N2,
                A,
                wkend_idx[1:WKEND_IDX_N[m],m],
                cntct_weekends_mean[m],
                cntct_weekdays_mean[m],
                popByAge_abs[m,]
                );
        
        // generate Rt as weighted avg of R_ta
        Rt = RtByAge * popByAge[:,m];
    }
}


